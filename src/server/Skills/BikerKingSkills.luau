--[[
    BikerKingSkills.luau
    Implementation of Biker King class skills.
    Fire-themed brawler with burn DoT, AOE flames, and chain-stomp mobility.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CombatConfig = require(Shared:WaitForChild("Config"):WaitForChild("CombatConfig"))
local StatLib = require(Shared:WaitForChild("Lib"):WaitForChild("StatLib"))
local EnemyLib = require(Shared:WaitForChild("Lib"):WaitForChild("EnemyLib"))
local CombatLib = require(Shared:WaitForChild("Lib"):WaitForChild("CombatLib"))

local BikerKingSkills = {}
-- Helper to apply burn DoT to a single enemy
local function applyBurn(
	player: Player,
	enemy: Model,
	burnDamagePerTick: number,
	burnDuration: number,
	tickRate: number
)
	if not EnemyLib:IsAlive(enemy) then
		return
	end

	-- Mark as burning (prevent stacking multiple burns from same source)
	local burnTag = "Burn_" .. player.UserId
	if enemy:GetAttribute(burnTag) then
		-- Refresh duration by resetting the attribute
		enemy:SetAttribute(burnTag, tick())
		return
	end
	enemy:SetAttribute(burnTag, tick())

	task.spawn(function()
		local ticks = math.floor(burnDuration / tickRate)
		for _ = 1, ticks do
			task.wait(tickRate)
			if not enemy or not enemy.Parent then
				break
			end
			if not EnemyLib:IsAlive(enemy) then
				break
			end
			EnemyLib:TakeDamage(enemy, burnDamagePerTick)
		end
		if enemy and enemy.Parent then
			enemy:SetAttribute(burnTag, nil)
		end
	end)
end

--[[
    Inferno Ramp (M2 / Secondary)
    Buffs attack speed + immediately burns all nearby enemies.
    During the buff duration, continuously applies burn to nearby enemies.
]]
function BikerKingSkills.InfernoRamp(player: Player, skillData: any)
	print("[BikerKingSkills] Inferno Ramp triggered by", player.Name)
	local character = player.Character
	if not character then
		return
	end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return
	end

	local duration = skillData.Duration or 5
	local fireRateBuff = skillData.FireRateBuff or 1.5
	local burnDamageMult = skillData.BurnDamage or 0.3
	local burnDuration = skillData.BurnDuration or 3
	local burnTickRate = skillData.BurnTickRate or 0.5

	-- Calculate burn damage per tick from base damage
	local baseDamage = 10
	local damageStat = StatLib:GetStat(player, "Damage", baseDamage)
	local burnDamagePerTick = damageStat * burnDamageMult

	-- Apply attack speed buff (read by CombatController via StatLib)
	character:SetAttribute("Buff_InfernoRamp", true)
	character:SetAttribute("AttackRateBuff", fireRateBuff)

	-- Immediately burn nearby enemies and keep pulsing burns for the duration
	task.spawn(function()
		local startTime = tick()
		while tick() - startTime < duration do
			if not character or not character.Parent then
				break
			end
			if not rootPart or not rootPart.Parent then
				break
			end

			-- Find and burn all enemies in close range
			local enemies = CombatLib.getEnemiesInRadius(rootPart.Position, 12)
			for _, enemy in enemies do
				applyBurn(player, enemy, burnDamagePerTick, burnDuration, burnTickRate)
			end

			task.wait(0.5) -- Re-apply burn pulse every 0.5s
		end
	end)

	-- Cleanup after duration
	task.delay(duration, function()
		if character and character.Parent then
			character:SetAttribute("Buff_InfernoRamp", nil)
			character:SetAttribute("AttackRateBuff", nil)
		end
	end)
end

--[[
    Flame Circle (E / Skill1)
    Erupts a ring of fire around the player, damaging enemies in pulses.
]]
function BikerKingSkills.FlameCircle(player: Player, skillData: any)
	print("[BikerKingSkills] Flame Circle triggered by", player.Name)
	local character = player.Character
	if not character then
		return
	end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return
	end

	local radius = skillData.Radius or 18
	local duration = skillData.Duration or 3
	local tickRate = skillData.TickRate or 0.5
	local damageMult = skillData.Damage or 1.5

	local baseDamage = 10
	local damageStat = StatLib:GetStat(player, "Damage", baseDamage)
	local damagePerTick = damageStat * damageMult

	-- Apply 20% Damage Resistance during Flame Circle
	character:SetAttribute("DamageResistance", 0.2)

	-- Pulse damage in ticks
	task.spawn(function()
		local ticks = math.floor(duration / tickRate)
		for _ = 1, ticks do
			if not character or not character.Parent then
				break
			end
			if not rootPart or not rootPart.Parent then
				break
			end

			local enemies = CombatLib.getEnemiesInRadius(rootPart.Position, radius)
			print("[BikerKingSkills] Flame Circle tick", i, "- found", #enemies, "enemies")

			for _, enemy in enemies do
				if EnemyLib:IsAlive(enemy) then
					EnemyLib:TakeDamage(enemy, damagePerTick)
				end
			end

			task.wait(tickRate)
		end

		-- Cleanup
		if character and character.Parent then
			character:SetAttribute("DamageResistance", nil)
		end
	end)
end

--[[
    Meteor Stomp (R / Skill2)
    Launch into the air, slam down with AOE damage.
    Landing on enemies bounces you back up for chain stomps.
]]
function BikerKingSkills.MeteorStomp(player: Player, skillData: any)
	print("[BikerKingSkills] Meteor Stomp triggered by", player.Name)
	local character = player.Character
	if not character then
		return
	end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return
	end

	local launchForce = skillData.LaunchForce or 80
	local bounceForce = skillData.BounceForce or 60
	local maxBounces = skillData.MaxBounces or 5
	local radius = skillData.Radius or 12
	local damageMult = skillData.Damage or 2.0

	local baseDamage = 10
	local damageStat = StatLib:GetStat(player, "Damage", baseDamage)
	local stompDamage = damageStat * damageMult

	-- Apply 50% Damage Resistance during stomp
	character:SetAttribute("DamageResistance", 0.5)

	-- Initial launch upward
	rootPart.AssemblyLinearVelocity = Vector3.new(0, launchForce, 0)

	-- Stomp loop
	task.spawn(function()
		local bounceCount = 0

		-- Wait until we start falling
		task.wait(0.3)

		while bounceCount < maxBounces do
			if not character or not character.Parent then
				break
			end
			if not rootPart or not rootPart.Parent then
				break
			end

			-- Check if we're moving downward and near ground/enemies
			local velocity = rootPart.AssemblyLinearVelocity
			if velocity.Y < -5 then
				-- Raycast downward to check for ground proximity
				local rayParams = RaycastParams.new()
				rayParams.FilterType = Enum.RaycastFilterType.Exclude
				rayParams.FilterDescendantsInstances = { character }

				local ray = workspace:Raycast(rootPart.Position, Vector3.new(0, -6, 0), rayParams)

				if ray then
					-- We're close to something — STOMP!
					local stompPos = rootPart.Position

					-- Find enemies in stomp radius
					local enemies = CombatLib.getEnemiesInRadius(stompPos, radius)
					local hitEnemy = false

					print(
						"[BikerKingSkills] Meteor Stomp landing - found",
						#enemies,
						"enemies (bounce",
						bounceCount + 1,
						")"
					)

					for _, enemy in enemies do
						local enemyRoot = enemy:FindFirstChild("HumanoidRootPart") or enemy.PrimaryPart

						if EnemyLib:IsAlive(enemy) then
							EnemyLib:TakeDamage(enemy, stompDamage)
							hitEnemy = true

							-- Slam enemies downward/outward
							if enemyRoot then
								local dir = (enemyRoot.Position - stompPos).Unit
								enemyRoot.AssemblyLinearVelocity = dir * 20 + Vector3.new(0, -15, 0)
							end
						end
					end

					bounceCount += 1

					if hitEnemy and bounceCount < maxBounces then
						-- Bounce back up off enemy heads!
						rootPart.AssemblyLinearVelocity = Vector3.new(0, bounceForce, 0)
						task.wait(0.3) -- Brief pause before next stomp check
					else
						-- Missed enemies or max bounces — done
						break
					end
				end
			end

			task.wait(0.05) -- Check frequently
		end

		-- Cleanup
		if character and character.Parent then
			character:SetAttribute("DamageResistance", nil)
		end
	end)
end

return BikerKingSkills
