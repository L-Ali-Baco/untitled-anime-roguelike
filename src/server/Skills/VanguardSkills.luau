--[[
    VanguardSkills.luau
    Implementation of Vanguard class skills.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local _CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local _CombatConfig = require(Shared:WaitForChild("Config"):WaitForChild("CombatConfig"))
local StatLib = require(Shared:WaitForChild("Lib"):WaitForChild("StatLib"))
local EnemyLib = require(Shared:WaitForChild("Lib"):WaitForChild("EnemyLib"))
local CombatLib = require(Shared:WaitForChild("Lib"):WaitForChild("CombatLib"))

-- ItemService is used to read EchoBlade stacks from the player's inventory.
-- Lazy-required to avoid issues with service boot order.
local ItemService = nil
local function getItemService()
	if not ItemService then
		ItemService = require(script.Parent.Parent.Services.ItemService)
	end
	return ItemService
end

local VanguardSkills = {}

--[[
    Aerial Slash (M2)
    A crescent slash WAVE that travels forward up to Range studs.
    - Hitbox moves at TravelSpeed studs/sec, checking enemies each step
    - Flying/airborne enemies (above player by FlyingHeightThreshold) take FlyingDamageMultiplier × damage
    - Each enemy is only hit once per cast
]]
--[[
    isEcho: when true this is the EchoBlade secondary cast.
    The isEcho flag is what prevents infinite recursion — an echo can never
    spawn another echo, so the call depth is always exactly 2 (main → echo).
]]
function VanguardSkills.AerialSlash(player: Player, skillData: any, targetPos: Vector3?, isEcho: boolean?)
	local character = player.Character
	if not character then
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return
	end

	-- Base calculations
	local baseDamage = skillData.Damage or 25
	local damageMult = skillData.DamageMultiplier or 1.0
	local damageStat = StatLib:GetStat(player, "Damage", baseDamage)
	local baseTotalDmg = damageStat * damageMult

	-- Hitbox params
	local hitboxSize = skillData.HitboxSize or Vector3.new(12, 10, 4)
	local _offsetZ = skillData.HitboxOffsetZ or -3
	local maxRange = skillData.Range or 40
	local travelSpeed = skillData.TravelSpeed or 60
	local heightBias = skillData.HeightBias or 0
	local lateralBias = skillData.LateralBias or 0
	local knockback = skillData.Knockback or 22
	local flyingThresh = skillData.FlyingHeightThreshold or 3
	local flyingMult = skillData.FlyingDamageMultiplier or 3.0
	local stepTime = 0.05

	-- AUTO-TARGET: Use the client-provided locked target position if available,
	-- otherwise fall back to looking forward
	local origin = rootPart.Position
	if targetPos then
		-- Snap character facing exactly to the requested position from client
		local lookDir = (targetPos - origin)
		lookDir = Vector3.new(lookDir.X, 0, lookDir.Z).Unit

		-- Sanity check: ensure valid vector
		if lookDir.Magnitude > 0.01 and lookDir == lookDir then
			rootPart.CFrame = CFrame.new(origin) * CFrame.lookAt(Vector3.zero, lookDir)
		end
	end

	-- Lock in the exact direction the hitbox will fly
	local castCFrame = rootPart.CFrame
	local forward = castCFrame.LookVector
	local right = castCFrame.RightVector
	local up = castCFrame.UpVector
	local playerY = origin.Y

	-- Overlap params — exclude caster
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = { character }

	-- Wait for animation impact frame, then start the wave
	task.delay(skillData.HitTime or 0.38, function()
		if not character or not character.Parent then
			return
		end

		local hitEnemies: { [Model]: boolean } = {}
		local traveled = 0

		while traveled < maxRange do
			if not character or not character.Parent then
				break
			end

			traveled = math.min(traveled + travelSpeed * stepTime, maxRange)

			-- Centre of the hitbox at this travel distance
			local center = origin + forward * traveled + up * heightBias + right * lateralBias

			local hitboxCF = CFrame.lookAt(center, center + forward)
			local parts = workspace:GetPartBoundsInBox(hitboxCF, hitboxSize, overlapParams)

			for _, part in parts do
				local model = part:FindFirstAncestorOfClass("Model")
				if model and not hitEnemies[model] and model ~= character then
					if EnemyLib:IsAlive(model) then
						hitEnemies[model] = true

						local enemyRoot = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
						local isFlying = enemyRoot and (enemyRoot.Position.Y > playerY + flyingThresh)
						local dmgMult = isFlying and flyingMult or 1.0
						local finalDmg = baseTotalDmg * dmgMult

						EnemyLib:TakeDamage(model, finalDmg)

						if isFlying then
							print("[VanguardSkills] AerialSlash FLYING HIT:", model.Name, "dmg:", finalDmg)
						end

						-- Knockback: away from origin + slight right bias (L→R momentum)
						if enemyRoot then
							local awayDir = (enemyRoot.Position - origin).Unit
							local lateralDir = Vector3.new(
								awayDir.X + right.X * 0.4,
								isFlying and -0.2 or 0.3, -- knock flying enemies DOWN slightly
								awayDir.Z + right.Z * 0.4
							).Unit
							enemyRoot.AssemblyLinearVelocity = lateralDir * knockback
						end
					end
				end
			end

			task.wait(stepTime)
		end
	end)

	-- ── EchoBlade: secondary hitbox ───────────────────────────────────────────
	-- Only main casts (isEcho == nil/false) can spawn an echo.
	-- This single guard is all that prevents infinite recursion.
	if not isEcho then
		local inv = getItemService():GetPlayerInventory(player)
		local echoStacks = inv["EchoBlade"] or 0
		if echoStacks > 0 then
			-- EchoDamage = MainDamage * clamp(0.3 + 0.1*stacks, 0.4, 1.2)
			-- Applied as a DamageMultiplier so StatLib item bonuses still apply correctly.
			local echoMult = math.clamp(0.3 + (0.1 * echoStacks), 0.4, 1.2)

			-- Shallow-copy skillData so we don't mutate the shared table
			local echoSkillData = {}
			for k, v in skillData do
				echoSkillData[k] = v
			end
			-- Scale the final multiplier; base damage feeds into StatLib unchanged
			echoSkillData.DamageMultiplier = (skillData.DamageMultiplier or 1.0) * echoMult
			-- Mark as echo so SkillVFX skips spawning a third slash
			echoSkillData.IsEcho = true

			-- 0.25s after the main cast, fire the echo in the exact same direction.
			-- targetPos is the originally locked aim point, so the echo follows the same line.
			task.delay(0.25, function()
				if player.Character then
					VanguardSkills.AerialSlash(player, echoSkillData, targetPos, true)
				end
			end)
		end
	end
end

--[[
    Iron Will (M2 → now unused as Secondary, kept for future re-assignment)
    Gain Shield + Damage Buff
]]
function VanguardSkills.IronWill(player: Player, skillData: any)
	local character = player.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local shieldAmount = humanoid.MaxHealth * skillData.ShieldPercent
	local currentShield = character:GetAttribute("Shield") or 0
	character:SetAttribute("Shield", currentShield + shieldAmount)
	character:SetAttribute("MaxShield", humanoid.MaxHealth)

	-- Apply Damage Buff attribute
	character:SetAttribute("Buff_IronWill", true)

	-- Decay Logic
	task.delay(skillData.Duration, function()
		if character then
			character:SetAttribute("Shield", 0)
			character:SetAttribute("Buff_IronWill", nil)
		end
	end)
end

--[[
    Seismic Slam (E)
    AoE Knockup + Damage
]]
function VanguardSkills.SeismicSlam(player: Player, skillData: any)
	print("[VanguardSkills] Seismic Slam triggered by", player.Name)
	local character = player.Character
	if not character then
		return
	end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return
	end

	local radius = skillData.Radius or 15
	local damageMult = skillData.Damage or 2.5
	local knockupForce = skillData.KnockupForce or 60

	-- Apply 50% Damage Resistance during jump
	character:SetAttribute("DamageResistance", 0.5)
	task.delay(1.5, function()
		if character then
			character:SetAttribute("DamageResistance", nil)
		end
	end)

	-- Determine Base Damage with StatLib scaling
	local baseDamage = 10
	local damageStat = StatLib:GetStat(player, "Damage", baseDamage)
	local totalDamage = damageStat * damageMult

	local enemies = CombatLib.getEnemiesInRadius(rootPart.Position, radius)
	print("[VanguardSkills] Seismic Slam found", #enemies, "enemies")

	for _, enemy in enemies do
		local enemyRoot = enemy:FindFirstChild("HumanoidRootPart") or enemy.PrimaryPart

		if EnemyLib:IsAlive(enemy) and enemyRoot then
			print(" - Hitting", enemy.Name, "for", totalDamage)
			-- Deal Damage
			EnemyLib:TakeDamage(enemy, totalDamage)

			-- Apply Knockup (Direct Velocity)
			local velocity = Vector3.new(0, knockupForce, 0)
			enemyRoot.AssemblyLinearVelocity = velocity
		end
	end
end

--[[
    Iron Grip (E)
    Yanks ALL enemies within Range studs toward the player.
    Animation: 111620876629826. Hit frame fires at HitTime (0.45s).
    Uses PivotTo each Heartbeat step (ease-in quad) — bypasses physics constraints
    entirely. AI's EnemyMoveVelocity.MaxForce is zeroed for the duration.
    - Target: 3 studs in front of caster's HumanoidRootPart
    - Pull duration: exactly 0.45 seconds
    - Post-pull: zero residual velocity, then 0.8s stun window
]]
function VanguardSkills.IronGrip(player: Player, skillData: any)
	print("[VanguardSkills] Iron Grip triggered by", player.Name)
	local character = player.Character
	if not character then
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return
	end

	local range = skillData.Range or 35
	local damageMult = skillData.Damage or 0.6
	local PULL_DURATION = 0.45

	local baseDamage = 10
	local damageStat = StatLib:GetStat(player, "Damage", baseDamage)
	local totalDmg = damageStat * damageMult

	-- Capture origin now (before delay) so pull radius check is accurate
	local pullAnchor = rootPart.Position

	task.delay(skillData.HitTime or 0.45, function()
		if not character or not character.Parent then
			return
		end

		-- Find all enemies in radius
		local enemies = CombatLib.getEnemiesInRadius(pullAnchor, range)
		print("[VanguardSkills] Iron Grip found", #enemies, "enemies")

		for _, enemy in enemies do
			if EnemyLib:IsAlive(enemy) then
				local enemyRoot = enemy:FindFirstChild("HumanoidRootPart") or enemy.PrimaryPart
				if enemyRoot then
					-- Small damage upfront (utility skill)
					EnemyLib:TakeDamage(enemy, totalDmg)

					-- ── PIVOT-TO PULL ───────────────────────────────────────────
					-- Directly PivotTo the enemy each Heartbeat step for PULL_DURATION.
					-- This bypasses all physics constraints and is immune to the AI's
					-- own LinearVelocity fighting back. We anchor the root part during
					-- the pull so the physics engine doesn't override the PivotTo.
					local aiLV = enemyRoot:FindFirstChild("EnemyMoveVelocity") :: LinearVelocity?
					local savedMaxForce = 50000
					if aiLV then
						savedMaxForce = aiLV.MaxForce
						aiLV.MaxForce = 0
						aiLV.PlaneVelocity = Vector2.zero
					end

					-- Anchor the enemy so PivotTo is authoritative
					enemyRoot.Anchored = true
					enemyRoot.AssemblyLinearVelocity = Vector3.zero

					local function restoreMobility()
						if aiLV and aiLV.Parent then
							aiLV.MaxForce = savedMaxForce
						end
						if enemyRoot and enemyRoot.Parent then
							enemyRoot.Anchored = false
							enemyRoot.AssemblyLinearVelocity = Vector3.zero
						end
					end

					pcall(function()
						enemyRoot:SetNetworkOwner(nil)
					end)

					-- Capture start pivot so we can lerp from it
					local startPos = enemy:GetPivot().Position
					local pullElapsed = 0
					local pullConn: RBXScriptConnection
					pullConn = RunService.Heartbeat:Connect(function(dt: number)
						pullElapsed += dt

						-- Guards
						if not enemyRoot or not enemyRoot.Parent then
							pullConn:Disconnect()
							restoreMobility()
							return
						end
						if not EnemyLib:IsAlive(enemy) then
							pullConn:Disconnect()
							restoreMobility()
							return
						end

						-- Suppress AI mover every frame
						if aiLV and aiLV.Parent then
							aiLV.PlaneVelocity = Vector2.zero
						end
						enemyRoot.AssemblyLinearVelocity = Vector3.zero

						-- Ease-in quad: slow start, snaps fast at end (chain-yank feel)
						local t = math.min(pullElapsed / PULL_DURATION, 1)
						local easedT = t * t
						local targetPos = rootPart.Position + rootPart.CFrame.LookVector * 3
						local newPos = startPos:Lerp(targetPos, easedT)
						local facingAngle = math.atan2(-rootPart.CFrame.LookVector.X, -rootPart.CFrame.LookVector.Z)
						enemy:PivotTo(CFrame.new(newPos) * CFrame.Angles(0, facingAngle, 0))

						if t >= 1 then
							pullConn:Disconnect()
							enemyRoot.AssemblyLinearVelocity = Vector3.zero
							enemyRoot.AssemblyAngularVelocity = Vector3.zero
							task.defer(restoreMobility)
							-- Brief stun so player gets a free hit window
							enemy:SetAttribute("Stunned", true)
							task.delay(0.8, function()
								if enemy and enemy.Parent then
									enemy:SetAttribute("Stunned", nil)
								end
							end)
						end
					end)
				end
			end
		end
	end)
end

--[[
    Blade Storm (R)
    Rapid cone attacks with forward momentum
]]
function VanguardSkills.BladeStorm(player: Player, skillData: any)
	print("[VanguardSkills] Blade Storm triggered")
	local character = player.Character
	if not character then
		return
	end
	local rootPart = character:FindFirstChild("HumanoidRootPart")

	local duration = skillData.Duration or 1.5
	local hitCount = skillData.HitCount or 6
	local damageMult = skillData.Damage or 0.8
	local baseDamage = 10
	local damageStat = StatLib:GetStat(player, "Damage", baseDamage)
	local damagePerHit = damageStat * damageMult

	local interval = duration / hitCount

	-- Apply 30% Damage Resistance during spin
	character:SetAttribute("DamageResistance", 0.3)
	task.delay(duration, function()
		if character then
			character:SetAttribute("DamageResistance", nil)
		end
	end)

	-- Apply forward momentum (BodyVelocity)
	local bv = Instance.new("BodyVelocity")
	bv.Name = "SkillMomentum"
	bv.MaxForce = Vector3.new(10000, 0, 10000)
	bv.Velocity = rootPart.CFrame.LookVector * 16 -- Move at run speed
	bv.Parent = rootPart
	game.Debris:AddItem(bv, duration)

	-- Spawn a thread to perform hits
	task.spawn(function()
		for i = 1, hitCount do
			if not character or not character.Parent then
				break
			end

			-- Update momentum direction (if player turns)
			bv.Velocity = rootPart.CFrame.LookVector * 16

			-- Cone Check
			local forward = rootPart.CFrame.LookVector
			local enemies = CombatLib.getEnemiesInRadius(rootPart.Position, 20) -- Increased Range (was 15)

			for _, enemy in enemies do
				local enemyPos = enemy:GetPivot().Position
				local dir = (enemyPos - rootPart.Position).Unit
				local angle = math.acos(math.clamp(forward:Dot(dir), -1, 1))

				if angle < math.rad(80) then -- Increased Cone (was 60, now 80 degrees - very wide)
					if EnemyLib:IsAlive(enemy) then
						EnemyLib:TakeDamage(enemy, damagePerHit)
						-- Small knockback
						local enemyRoot = enemy:FindFirstChild("HumanoidRootPart") or enemy.PrimaryPart
						if enemyRoot then
							enemyRoot.AssemblyLinearVelocity = dir * 15 + Vector3.new(0, 5, 0)
						end
					end
				end
			end

			task.wait(interval)
		end
	end)
end

return VanguardSkills
