--[[
    CombatService.luau
    Server-side combat handling.
    
    Responsibilities:
    - Receive attack requests from clients (melee and ranged)
    - Validate hits (range, cooldown, target exists)
    - Apply damage to target Humanoid
    - Apply knockback
    - Broadcast hit confirmation to clients
    - Anti-cheat: rate limiting, distance checks
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

-- Wait for shared modules
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local CombatConfig = require(Shared:WaitForChild("Config"):WaitForChild("CombatConfig"))
local ClassConfig = require(Shared:WaitForChild("Config"):WaitForChild("ClassConfig"))
local StatLib = require(Shared:WaitForChild("Lib"):WaitForChild("StatLib"))
local EnemyLib = require(Shared:WaitForChild("Lib"):WaitForChild("EnemyLib"))

-- Services
local ClassService = require(script.Parent.ClassService)
local ItemService = require(script.Parent.ItemService)

local CombatService = {
	Name = "CombatService",
}

local ProcService = nil -- Set in Start to avoid circular dependency chain risks

-- Track last attack time per player (anti-cheat rate limiting)
local playerLastAttack: { [Player]: number } = {}
local playerLastRangedAttack: { [Player]: number } = {}

-- Track last attack ID per player (for AOE rate limiting - allow multiple hits per attack)
local playerLastAttackId: { [Player]: string } = {}

-- Track hits per attack to prevent duplicate damage
local attackHitTargets: { [string]: { [Model]: boolean } } = {}
-- OPTIMIZATION: Centralized queue for attack cleanup to reduce scheduler overhead.
-- Using pointer-based queue for O(1) removal instead of table.remove/table.move which is O(n).
local activeAttacks: { [number]: { id: string, expiry: number } } = {}
local activeAttacksHead = 1
local activeAttacksTail = 0

-- Track combo state per player to prevent sequence exploits (e.g. skipping to attack 3)
local playerComboState: { [Player]: { CurrentIndex: number, LastAttackTime: number } } = {}

--[[
    Get the root part of a target (works for players and NPCs)
]]
local function getTargetRoot(target: Model): BasePart?
	return target:FindFirstChild("HumanoidRootPart") or target:FindFirstChild("Torso") or target.PrimaryPart
end

--[[
    Check if target is alive (works for both enemies and Humanoid-based entities)
]]
local function isTargetAlive(target: Model): boolean
	return EnemyLib:IsAlive(target)
end

--[[
    Validate that attack request is legitimate
    Returns: isValid, errorReason
    
    NOTE: attackId parameter added to support AOE attacks.
    Multiple hits with the SAME attackId are allowed (different targets in one swing).
    Rate limiting only applies when attackId changes (new attack).
]]
local function validateAttack(
	player: Player,
	attackIndex: number,
	targetModel: Model?,
	attackId: string?
): (boolean, string?)
	-- Check player has character
	local character = player.Character
	if not character then
		return false, "No character"
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false, "Player dead"
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return false, "No root part"
	end

	-- Get Class Service for dynamic rate limiting
	local className = ClassService:GetPlayerClass(player) or "Warrior"
	local classData = ClassConfig[className]

	-- Determine rate limit based on class
	local minInterval = CombatConfig.Server.MinAttackInterval
	if className == "Scrapper" then
		-- Use configured ranged attack speed but allow a small latency bufferrior" then
		minInterval = CombatConfig.Combo.AutoAttackInterval
	elseif className == "Warrior" then
		minInterval = CombatConfig.Combo.AutoAttackInterval
	end

	-- Apply Attack Speed multiplier from items
	-- Higher attack speed = Lower interval
	local inventory = ItemService:GetPlayerInventory(player)
	local attackSpeedMult = StatLib:GetStat(player, "AttackRate", 1.0, inventory)
	minInterval = minInterval / attackSpeedMult

	-- Add small grace period for latency variance (ping jitter)
	minInterval = minInterval * 0.9

	-- Rate limiting (anti-cheat)
	-- IMPORTANT: Skip rate limit if this is the same attack (AOE hitting multiple targets)
	-- Multiple hits with the same attackId are allowed within the same swing
	local now = tick()
	local lastAttack = playerLastAttack[player] or 0
	local lastAttackId = playerLastAttackId[player]

	-- Only rate limit if this is a NEW attack (different attackId)
	if attackId and lastAttackId == attackId then
		-- Same attack, allow through (AOE multi-hit)
	else
		-- New attack: Check rate limit
		if now - lastAttack < minInterval then
			return false, "Attack too fast"
		end

		-- New attack: Check Combo Sequence (Security Fix)
		-- BikerKing uses Flamethrower (tick-based), always index 1
		if className == "BikerKing" then
			if attackIndex ~= 1 then
				return false, "BikerKing invalid attack index"
			end
		else
			-- Standard Melee Combo (1 -> 2 -> 3)
			local comboState = playerComboState[player]
			if not comboState then
				comboState = { CurrentIndex = 0, LastAttackTime = 0 }
				playerComboState[player] = comboState
			end

			-- Check for timeout (reset combo)
			-- ResetTime + small latency buffer
			local resetTime = CombatConfig.Combo.ResetTime + 0.2
			local timeSinceLastCombo = now - comboState.LastAttackTime

			if attackIndex == 1 then
				-- Valid start of combo (or restart)
				-- Always allowed
			elseif attackIndex > 1 then
				-- Must be sequential and within time window
				if comboState.CurrentIndex ~= attackIndex - 1 then
					-- Invalid sequence (e.g. skipped 1 to get to 2, or repeated 2)
					return false,
						"Invalid combo sequence: Expected " .. (comboState.CurrentIndex + 1) .. ", got " .. attackIndex
				end

				if timeSinceLastCombo > resetTime then
					-- Combo expired, should have restarted at 1
					return false, "Combo expired"
				end
			else
				return false, "Invalid attack index"
			end
		end
	end

	-- If no target, attack is valid (just swinging at air)
	if not targetModel then
		return true, nil
	end

	-- Validate target is alive
	if not isTargetAlive(targetModel) then
		return false, "Target already dead"
	end

	-- Validate target is tagged as enemy (or is a training dummy)
	local isEnemy = CollectionService:HasTag(targetModel, CombatConfig.Targeting.TargetTag)
	local isDummy = CollectionService:HasTag(targetModel, "TrainingDummy")
	if not isEnemy and not isDummy then
		return false, "Target is not an enemy"
	end

	-- Validate distance (anti-cheat)
	local targetRoot = getTargetRoot(targetModel)
	if not targetRoot then
		return false, "Target has no root"
	end

	local distance = (rootPart.Position - targetRoot.Position).Magnitude
	if distance > CombatConfig.Server.MaxAttackRange then
		return false, "Target too far"
	end

	return true, nil
end

--[[
    Apply knockback to a target
    
    IMPORTANT: We use direct velocity setting instead of ApplyImpulse because:
    1. ApplyImpulse adds instantaneous force that fights with Humanoid:MoveTo()
    2. During hitstun, MoveTo is paused, so velocity changes work smoothly
    3. Direct velocity is more predictable and easier to tune
]]
local function applyKnockback(attacker: Model, target: Model, knockbackForce: number, customDirection: Vector3?)
	local attackerRoot = attacker:FindFirstChild("HumanoidRootPart")
	local targetRoot = getTargetRoot(target)

	if not attackerRoot or not targetRoot then
		return
	end

	-- Calculate knockback direction
	local direction
	if customDirection and customDirection.Magnitude > 0.01 then
		direction = customDirection
	else
		direction = (targetRoot.Position - attackerRoot.Position)
	end
	direction = Vector3.new(direction.X, 0, direction.Z)

	if direction.Magnitude < 0.1 then
		-- Attacker and target are too close, use attacker's facing direction
		direction = attackerRoot.CFrame.LookVector
		direction = Vector3.new(direction.X, 0, direction.Z)
	end
	direction = direction.Unit

	-- Calculate knockback velocity (smaller values work better with Humanoid)
	-- knockbackForce is typically 5-12, so multiply by 2-3 for reasonable push
	local knockbackSpeed = knockbackForce * 2.5
	local upwardPop = 3 -- Small upward component for visual "hit" feel

	local knockbackVelocity = direction * knockbackSpeed + Vector3.new(0, upwardPop, 0)

	-- Apply velocity directly (works during hitstun when MoveTo is paused)
	targetRoot.AssemblyLinearVelocity = knockbackVelocity
end

--[[
	Internal helper to unify damage application logic
	Returns: didDamage, targetDied
]]
function CombatService.ApplyDamage(
	attacker: Player,
	target: Model,
	attackId: string,
	baseDamage: number,
	knockbackForce: number?,
	isRanged: boolean,
	customKnockbackDir: Vector3?
): (boolean, boolean)
	-- Check if we already hit this target with this attack ID
	if attackHitTargets[attackId] and attackHitTargets[attackId][target] then
		return false, false -- Duplicate hit ignored
	end

	-- Mark target as hit by this attack
	if not attackHitTargets[attackId] then
		attackHitTargets[attackId] = {}
	end
	attackHitTargets[attackId][target] = true

	-- Get target state
	if not EnemyLib:IsAlive(target) then
		return false, false
	end

	-- Calculate damage
	-- Base damage -> Modified by Items -> Global Multiplier
	local inventory = ItemService:GetPlayerInventory(attacker)
	local damage = StatLib:GetStat(attacker, "Damage", baseDamage, inventory)
	damage = damage * (CombatConfig.Server.DamageMultiplier or 1)

	-- Calculate Critical Hit
	local critChance = StatLib:GetStat(attacker, "CritChance", 0, inventory) -- Base 0%
	local isCrit = math.random() <= critChance
	if isCrit then
		damage = damage * 2.0
	end

	-- Apply Damage Resistance (e.g. from Skills)
	local resistance = target:GetAttribute("DamageResistance") or 0
	if resistance > 0 then
		damage = damage * (1 - math.clamp(resistance, 0, 1))
	end

	-- Apply damage (Shield Logic)
	local currentShield = target:GetAttribute("Shield") or 0

	if currentShield > 0 then
		if currentShield >= damage then
			-- Shield absorbs all damage
			target:SetAttribute("Shield", currentShield - damage)
			damage = 0
		else
			-- Shield breaks
			damage = damage - currentShield
			target:SetAttribute("Shield", 0)
		end
	end

	if damage > 0 then
		EnemyLib:TakeDamage(target, damage)
	end

	if isRanged then
		local currentHP = EnemyLib:GetHealth(target)
		print("[CombatService] Dealt", damage, "ranged damage to", target.Name, "- HP:", currentHP)
	end

	-- Apply knockback
	local attackerCharacter = attacker.Character
	if attackerCharacter and knockbackForce then
		applyKnockback(attackerCharacter, target, knockbackForce, customKnockbackDir)
	end

	-- Process On-Hit Effects
	if ProcService then
		ProcService:ProcessHit(attacker, target, damage, isCrit)
	end

	-- Check if target died
	local targetDied = not EnemyLib:IsAlive(target)

	if isRanged then
		print(
			"[CombatService] processRangedDamage: Target health after damage:",
			EnemyLib:GetHealth(target),
			"died:",
			targetDied
		)
	end

	if targetDied and ProcService then
		ProcService:ProcessKill(attacker, target)
	end

	return true, targetDied
end

--[[
    Process damage on a target
    Returns: didDamage, targetDied
]]
local function processDamage(attacker: Player, target: Model, attackIndex: number, attackId: string): (boolean, boolean)
	-- Strict ID check: Attack ID must be valid string
	if not attackId or attackId == "" then
		return false, false
	end

	-- Get attack data
	local attackData = CombatConfig.Attacks[attackIndex]
	if not attackData then
		return false, false
	end

	return CombatService.ApplyDamage(attacker, target, attackId, attackData.Damage, attackData.Knockback, false)
end

--[[
    Handle attack request from client
]]
local function onRequestAttack(player: Player, attackIndex: number, targetOrTargets: any, attackId: any)
	-- Normalize input to list of targets
	local targets = {}
	if typeof(targetOrTargets) == "Instance" then
		targets = { targetOrTargets }
	elseif type(targetOrTargets) == "table" then
		targets = targetOrTargets
	end

	-- Validate rate limit (check against first target or nil)
	-- This checks if the *batch* is allowed at this time
	-- We use targets[1] to validate distance/health for at least one target if present
	local checkTarget = targets[1]
	local isValid, errorReason = validateAttack(player, attackIndex, checkTarget, attackId)

	if not isValid then
		-- Suppress "Attack too fast" warnings for rapid fire
		if errorReason ~= "Attack too fast" then
			-- warn("[CombatService] Invalid attack from", player.Name, ":", errorReason)
		end
		return
	end

	-- Process all targets
	-- Note: We haven't updated playerLastAttack yet, so validateAttack will pass rate checks for all targets in this batch
	for _, target in targets do
		local tValid, tError = validateAttack(player, attackIndex, target, attackId)
		if tValid then
			local didDamage, targetDied = processDamage(player, target, attackIndex, attackId)

			if didDamage then
				-- Get attack data for VFX info
				local attackData = CombatConfig.Attacks[attackIndex]

				-- Get hit position (target's position)
				local targetRoot = getTargetRoot(target)
				local hitPosition = targetRoot and targetRoot.Position or Vector3.zero

				-- Send hit confirmation to ALL clients (for VFX)
				local hitConfirmedRemote = Remotes:GetEvent("HitConfirmed")
				if hitConfirmedRemote then
					hitConfirmedRemote:FireAllClients({
						Attacker = player,
						Target = target,
						AttackIndex = attackIndex,
						HitPosition = hitPosition,
						Hitstop = attackData.Hitstop,
						ScreenShake = attackData.ScreenShake,
						TargetDied = targetDied,
					})
				end

				-- If target died, fire death event
				if targetDied then
					local enemyDiedRemote = Remotes:GetEvent("EnemyDied")
					if enemyDiedRemote then
						enemyDiedRemote:FireAllClients({
							Target = target,
							Killer = player,
							Position = hitPosition,
						})
					end
					print("[CombatService]", player.Name, "killed", target.Name)
				end
			end
		end
	end

	-- Update last attack time and ID (Close the rate limit window)
	local lastAttackId = playerLastAttackId[player]
	if attackId ~= lastAttackId then
		playerLastAttack[player] = tick()
		playerLastAttackId[player] = attackId

		-- Update Combo State
		if not playerComboState[player] then
			playerComboState[player] = { CurrentIndex = 0, LastAttackTime = 0 }
		end
		playerComboState[player].CurrentIndex = attackIndex
		playerComboState[player].LastAttackTime = tick()
	end

	-- Cleanup attack hit tracking after a short delay
	-- OPTIMIZATION: Use centralized queue instead of task.delay to reduce scheduler overhead
	activeAttacksTail += 1
	activeAttacks[activeAttacksTail] = { id = attackId, expiry = tick() + 1 }
end

-- ============================================================================
-- RANGED ATTACK HANDLING
-- ============================================================================

--[[
    Validate ranged attack request
    Returns: isValid, errorReason
]]
local function validateRangedAttack(player: Player, targetModel: Model?, hitPosition: Vector3): (boolean, string?)
	-- Check player has character
	local character = player.Character
	if not character then
		return false, "No character"
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false, "Player dead"
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return false, "No root part"
	end

	-- Rate limiting (anti-cheat)
	local now = tick()
	local lastRangedAttack = playerLastRangedAttack[player] or 0
	local minInterval = (ClassConfig.Server.MinRangedInterval or 0.08) * 0.9 -- 10% grace period
	if now - lastRangedAttack < minInterval then
		return false, "Ranged attack too fast"
	end

	-- If no target, attack is valid (just a miss)
	if not targetModel then
		return true, nil
	end

	-- NOTE: Aim angle validation REMOVED
	-- The client has auto-aim that rotates the character to face targets,
	-- but this rotation may not replicate to server fast enough when moving.
	-- Since we have distance validation and the client handles targeting,
	-- removing this check allows shooting while moving backwards.
	-- Anti-cheat is still enforced via distance check and rate limiting.

	-- Validate target is alive
	if not isTargetAlive(targetModel) then
		return false, "Target already dead"
	end

	-- Validate target is tagged as enemy (or is a training dummy)
	local isEnemy = CollectionService:HasTag(targetModel, CombatConfig.Targeting.TargetTag)
	local isDummy = CollectionService:HasTag(targetModel, "TrainingDummy")

	if not isEnemy and not isDummy then
		-- Log this once for debugging
		warn("[CombatService] Target", targetModel.Name, "not tagged. Needs 'Enemy' or 'TrainingDummy' tag")
		return false, "Target is not an enemy"
	end

	-- Validate distance (anti-cheat) - use ranged max range
	local targetRoot = getTargetRoot(targetModel)
	if not targetRoot then
		return false, "Target has no root"
	end

	local maxRange = ClassConfig.Server.MaxRangedRange or 70
	local distance = (rootPart.Position - targetRoot.Position).Magnitude

	-- Add generous buffer for movement latency (10 studs)
	if distance > maxRange + 10 then
		return false, "Target too far for ranged attack"
	end

	return true, nil
end

--[[
    Process ranged damage on a target
    Returns: didDamage, targetDied
]]
local function processRangedDamage(
	attacker: Player,
	target: Model,
	hitPosition: Vector3,
	attackId: string
): (boolean, boolean)
	-- Get ranged attack data from config
	local rangedData = ClassConfig.Scrapper.RangedAttack
	if not rangedData then
		return false, false
	end

	return CombatService.ApplyDamage(attacker, target, attackId, rangedData.Damage, rangedData.Knockback, true)
end

local function onRequestRangedHit(
	player: Player,
	targetModel: Model?,
	hitPosition: Vector3,
	attackId: string,
	isShredShot: boolean?
)
	-- Type validation
	if targetModel ~= nil and typeof(targetModel) ~= "Instance" then
		return
	end
	if typeof(hitPosition) ~= "Vector3" then
		return
	end
	if typeof(attackId) ~= "string" then
		return
	end

	-- Validate the attack
	local isValid, errorReason = validateRangedAttack(player, targetModel, hitPosition)
	if not isValid then
		return
	end

	-- Update last attack time
	playerLastRangedAttack[player] = tick()

	-- If no target, nothing more to do (miss)
	if not targetModel then
		return
	end

	-- Process damage
	local didDamage, targetDied = processRangedDamage(player, targetModel, hitPosition, attackId)

	if not didDamage then
		return
	end

	-- Armor Shred Logic
	if isShredShot and ClassConfig.Scrapper.Skills.KineticScrubber then
		local config = ClassConfig.Scrapper.Skills.KineticScrubber
		local hitRadius = config.Radius
		local shredAmount = config.ShredAmount

		local blastParams = OverlapParams.new()
		local ignoreList = {}
		for _, p in ipairs(Players:GetPlayers()) do
			if p.Character then
				table.insert(ignoreList, p.Character)
			end
		end
		blastParams.FilterDescendantsInstances = ignoreList

		local blastParts = workspace:GetPartBoundsInRadius(hitPosition, hitRadius, blastParams)
		local hitEnemies = {}

		for _, bPart in ipairs(blastParts) do
			local bModel = bPart:FindFirstAncestorOfClass("Model")
			if bModel and EnemyLib:IsAlive(bModel) and not hitEnemies[bModel] then
				hitEnemies[bModel] = true

				-- Apply Shred attribute
				local currentRes = bModel:GetAttribute("DamageResistance") or 0
				bModel:SetAttribute("DamageResistance", currentRes - shredAmount)

				-- Remove shred after duration
				task.delay(config.ShredDuration, function()
					if bModel and EnemyLib:IsAlive(bModel) then
						local newRes = bModel:GetAttribute("DamageResistance") or 0
						bModel:SetAttribute("DamageResistance", newRes + shredAmount)
					end
				end)
			end
		end

		-- Could fire a custom Client VFX event here to show the explosion, for now rely on bullet VFX
	end

	-- Get ranged attack data for VFX info
	local rangedData = ClassConfig.Scrapper.RangedAttack

	-- Send hit confirmation to ALL clients (for VFX)
	local rangedHitConfirmedRemote = Remotes:GetEvent("RangedHitConfirmed")
	if rangedHitConfirmedRemote then
		rangedHitConfirmedRemote:FireAllClients({
			Attacker = player,
			Target = targetModel,
			HitPosition = hitPosition,
			Hitstop = rangedData and rangedData.Hitstop or 0.01,
			ScreenShake = rangedData and rangedData.ScreenShake or 0.1,
			TargetDied = targetDied,
		})
	end

	-- If target died, fire death event
	if targetDied then
		local enemyDiedRemote = Remotes:GetEvent("EnemyDied")
		if enemyDiedRemote then
			enemyDiedRemote:FireAllClients({
				Target = targetModel,
				Killer = player,
				Position = hitPosition,
			})
		end

		print("[CombatService]", player.Name, "killed", targetModel.Name, "(ranged)")
	end

	-- Cleanup attack hit tracking after a short delay
	-- OPTIMIZATION: Use centralized queue instead of task.delay to reduce scheduler overhead
	activeAttacksTail += 1
	activeAttacks[activeAttacksTail] = { id = attackId, expiry = tick() + 0.5 }
end

--[[
    Handle dash hit from Scrapper's Scavenger Slide
]]
local function onRequestDashHit(player: Player, targetModel: Model?)
	if not targetModel then
		return
	end

	local className = ClassService:GetPlayerClass(player)
	if className ~= "Scrapper" then
		return
	end

	local config = ClassConfig.Scrapper.Skills.ScavengersSlide
	if not config then
		return
	end

	-- Distance check
	local playerChar = player.Character
	local rootPart = playerChar and playerChar:FindFirstChild("HumanoidRootPart")
	local targetRoot = getTargetRoot(targetModel)

	if rootPart and targetRoot then
		-- Distance tolerance for slide hits
		if (rootPart.Position - targetRoot.Position).Magnitude <= 20 then
			local blastParams = OverlapParams.new()
			local ignoreList = {}
			for _, p in ipairs(Players:GetPlayers()) do
				if p.Character then
					table.insert(ignoreList, p.Character)
				end
			end
			blastParams.FilterDescendantsInstances = ignoreList

			local blastParts = workspace:GetPartBoundsInRadius(targetRoot.Position, config.AOERadius, blastParams)
			local hitEnemies = {}
			local enemiesStruck = 0

			for _, bPart in ipairs(blastParts) do
				local bModel = bPart:FindFirstAncestorOfClass("Model")
				if bModel and EnemyLib:IsAlive(bModel) and not hitEnemies[bModel] then
					hitEnemies[bModel] = true
					enemiesStruck += 1

					local bRoot = getTargetRoot(bModel)
					local pushDir = nil
					if bRoot then
						-- Push radially outward from the primary hit target
						pushDir = bRoot.Position - targetRoot.Position
						if pushDir.Magnitude < 0.1 then
							-- If it's the exact target, push them forward along the scrapper's dash path
							pushDir = rootPart.CFrame.LookVector
						end
					end

					CombatService.ApplyDamage(
						player,
						bModel,
						"DashHit_" .. tostring(tick()),
						config.Damage,
						config.Knockback,
						false,
						pushDir
					)
				end
			end

			if enemiesStruck > 0 then
				local addHeatEvent =
					require(game:GetService("ReplicatedStorage").Shared.Remotes):GetEvent("AddScrapperHeat")
				if addHeatEvent then
					addHeatEvent:FireClient(player, enemiesStruck * 25)
				end
			end
		end
	end
end

--[[
    Initialize the service
]]
function CombatService:Init()
	print("[CombatService] Initializing...")

	-- Initialize remotes (creates them if they don't exist)
	Remotes:InitServer()
end

--[[
    Start the service
]]
function CombatService:Start()
	print("[CombatService] Starting...")

	-- Start cleanup loop
	-- OPTIMIZATION: Batch cleanup operations to reduce scheduler overhead
	RunService.Heartbeat:Connect(function()
		local now = tick()

		-- Process queue from head (oldest) to tail (newest)
		-- O(1) removal by just incrementing head pointer
		while activeAttacksHead <= activeAttacksTail do
			local entry = activeAttacks[activeAttacksHead]

			if now >= entry.expiry then
				-- Cleanup hit tracking data
				attackHitTargets[entry.id] = nil

				-- Clear reference to allow GC
				activeAttacks[activeAttacksHead] = nil
				activeAttacksHead += 1
			else
				-- Since we insert in chronological order, if the oldest hasn't expired,
				-- none of the newer ones have either.
				break
			end
		end

		-- Optional: Reset indices if empty to prevent integer overflow (though unlikely with Luau numbers)
		if activeAttacksHead > activeAttacksTail then
			activeAttacksHead = 1
			activeAttacksTail = 0
		end
	end)

	-- Load ProcService
	ProcService = require(script.Parent.ProcService)

	-- Connect to melee attack request remote
	local requestAttackRemote = Remotes:GetEvent("RequestAttack")
	if requestAttackRemote then
		requestAttackRemote.OnServerEvent:Connect(onRequestAttack)
		print("[CombatService] Connected to RequestAttack remote")
	else
		warn("[CombatService] Failed to find RequestAttack remote!")
	end

	-- Connect to ranged attack request remote
	local requestRangedHitRemote = Remotes:GetEvent("RequestRangedHit")
	if requestRangedHitRemote then
		requestRangedHitRemote.OnServerEvent:Connect(onRequestRangedHit)
		print("[CombatService] Connected to RequestRangedHit remote")
	else
		warn("[CombatService] Failed to find RequestRangedHit remote!")
	end

	-- Connect to Dash Hit request remote
	local requestDashHitRemote = Remotes:GetEvent("RequestDashHit")
	if requestDashHitRemote then
		requestDashHitRemote.OnServerEvent:Connect(onRequestDashHit)
		print("[CombatService] Connected to RequestDashHit remote")
	end

	-- Cleanup when player leaves
	Players.PlayerRemoving:Connect(function(player)
		playerLastAttack[player] = nil
		playerLastRangedAttack[player] = nil
		playerLastAttackId[player] = nil
		playerComboState[player] = nil
	end)

	print("[CombatService] Started successfully")
end

-- Export private functions for testing
CombatService._processDamage = processDamage

return CombatService
