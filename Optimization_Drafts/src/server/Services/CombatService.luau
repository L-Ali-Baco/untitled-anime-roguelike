--[[
    CombatService.luau
    OPTIMIZED DRAFT - 2024-05-22

    Optimizations Applied:
    1.  **Queue Optimization**: Replaced O(N) `table.remove` with O(1) pointer-based queue for attack cleanup.
        - Prevents lag spikes during heavy combat.
    2.  **Spatial Replication**: Implemented `fireRelevantClients` to broadcast VFX events only to nearby players.
        - Significantly reduces network bandwidth usage.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local CombatConfig = require(Shared:WaitForChild("Config"):WaitForChild("CombatConfig"))
local ClassConfig = require(Shared:WaitForChild("Config"):WaitForChild("ClassConfig"))
local StatLib = require(Shared:WaitForChild("Lib"):WaitForChild("StatLib"))
local EnemyLib = require(Shared:WaitForChild("Lib"):WaitForChild("EnemyLib"))

local ClassService = require(script.Parent.ClassService)
local ItemService = require(script.Parent.ItemService)

local CombatService = {
	Name = "CombatService",
}

local ProcService = nil

-- Track last attack time per player
local playerLastAttack: { [Player]: number } = {}
local playerLastRangedAttack: { [Player]: number } = {}
local playerLastAttackId: { [Player]: string } = {}

-- Attack Hit Tracking
local attackHitTargets: { [string]: { [Model]: boolean } } = {}

-- OPTIMIZATION: Pointer-based Queue
local activeAttacks = {}
local activeAttacksHead = 1
local activeAttacksTail = 0

-- Track combo state
local playerComboState: { [Player]: { CurrentIndex: number, LastAttackTime: number } } = {}

-- ============================================================================
-- OPTIMIZATION: Helper Functions
-- ============================================================================

-- Spatial Broadcast (Bandwidth Optimization)
local REPLICATION_RADIUS = 200 -- Only replicate to players within 200 studs
local function fireRelevantClients(remoteEvent, position: Vector3, data: any)
    if not remoteEvent then return end

    -- If no position (global event), fall back to all clients
    if not position then
        remoteEvent:FireAllClients(data)
        return
    end

    for _, player in Players:GetPlayers() do
        local char = player.Character
        if char then
            local root = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
            if root then
                if (root.Position - position).Magnitude <= REPLICATION_RADIUS then
                    remoteEvent:FireClient(player, data)
                end
            end
        end
    end
end

-- ============================================================================

local function getTargetRoot(target: Model): BasePart?
	return target:FindFirstChild("HumanoidRootPart") or target:FindFirstChild("Torso") or target.PrimaryPart
end

local function isTargetAlive(target: Model): boolean
	return EnemyLib:IsAlive(target)
end

local function validateAttack(player: Player, attackIndex: number, targetModel: Model?, attackId: string?): (boolean, string?)
	local character = player.Character
	if not character then return false, "No character" end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return false, "Player dead" end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return false, "No root part" end

	local className = ClassService:GetPlayerClass(player) or "Warrior"
	local classData = ClassConfig[className]

	local minInterval = CombatConfig.Server.MinAttackInterval
	if className == "Gunner" then
		minInterval = classData.RangedAttack.FireRate
	elseif className == "Warrior" then
		minInterval = CombatConfig.Combo.AutoAttackInterval
	end

	local inventory = ItemService:GetPlayerInventory(player)
	local attackSpeedMult = StatLib:GetStat(player, "AttackRate", 1.0, inventory)
	minInterval = minInterval / attackSpeedMult
	minInterval = minInterval * 0.9

	local now = tick()
	local lastAttack = playerLastAttack[player] or 0
	local lastAttackId = playerLastAttackId[player]

	if attackId and lastAttackId == attackId then
		-- Same attack, allow through
	else
		if now - lastAttack < minInterval then return false, "Attack too fast" end

		if className == "BikerKing" then
			if attackIndex ~= 1 then return false, "BikerKing invalid attack index" end
		else
			local comboState = playerComboState[player]
			if not comboState then
				comboState = { CurrentIndex = 0, LastAttackTime = 0 }
				playerComboState[player] = comboState
			end

			local resetTime = CombatConfig.Combo.ResetTime + 0.2
			local timeSinceLastCombo = now - comboState.LastAttackTime

			if attackIndex == 1 then
			elseif attackIndex > 1 then
				if comboState.CurrentIndex ~= attackIndex - 1 then
					return false, "Invalid combo sequence"
				end
				if timeSinceLastCombo > resetTime then return false, "Combo expired" end
			else
				return false, "Invalid attack index"
			end
		end
	end

	if not targetModel then return true, nil end
	if not isTargetAlive(targetModel) then return false, "Target already dead" end

	local isEnemy = CollectionService:HasTag(targetModel, CombatConfig.Targeting.TargetTag)
	local isDummy = CollectionService:HasTag(targetModel, "TrainingDummy")
	if not isEnemy and not isDummy then return false, "Target is not an enemy" end

	local targetRoot = getTargetRoot(targetModel)
	if not targetRoot then return false, "Target has no root" end
	local distance = (rootPart.Position - targetRoot.Position).Magnitude
	if distance > CombatConfig.Server.MaxAttackRange then return false, "Target too far" end

	return true, nil
end

local function applyKnockback(attacker: Model, target: Model, knockbackForce: number)
	local attackerRoot = attacker:FindFirstChild("HumanoidRootPart")
	local targetRoot = getTargetRoot(target)
	if not attackerRoot or not targetRoot then return end

	local direction = (targetRoot.Position - attackerRoot.Position)
	direction = Vector3.new(direction.X, 0, direction.Z)
	if direction.Magnitude < 0.1 then
		direction = attackerRoot.CFrame.LookVector
		direction = Vector3.new(direction.X, 0, direction.Z)
	end
	direction = direction.Unit

	local knockbackSpeed = knockbackForce * 2.5
	local upwardPop = 3
	local knockbackVelocity = direction * knockbackSpeed + Vector3.new(0, upwardPop, 0)
	targetRoot.AssemblyLinearVelocity = knockbackVelocity
end

local function _applyDamage(attacker: Player, target: Model, attackId: string, baseDamage: number, knockbackForce: number?, isRanged: boolean): (boolean, boolean)
	if attackHitTargets[attackId] and attackHitTargets[attackId][target] then
		return false, false
	end

	if not attackHitTargets[attackId] then
		attackHitTargets[attackId] = {}
	end
	attackHitTargets[attackId][target] = true

	if not EnemyLib:IsAlive(target) then return false, false end

	local inventory = ItemService:GetPlayerInventory(attacker)
	local damage = StatLib:GetStat(attacker, "Damage", baseDamage, inventory)
	damage = damage * (CombatConfig.Server.DamageMultiplier or 1)

	local critChance = StatLib:GetStat(attacker, "CritChance", 0, inventory)
	local isCrit = math.random() <= critChance
	if isCrit then damage = damage * 2.0 end

	local resistance = target:GetAttribute("DamageResistance") or 0
	if resistance > 0 then damage = damage * (1 - math.clamp(resistance, 0, 1)) end

	local currentShield = target:GetAttribute("Shield") or 0
	if currentShield > 0 then
		if currentShield >= damage then
			target:SetAttribute("Shield", currentShield - damage)
			damage = 0
		else
			damage = damage - currentShield
			target:SetAttribute("Shield", 0)
		end
	end

	if damage > 0 then EnemyLib:TakeDamage(target, damage) end
	if isRanged then print("[CombatService] Dealt", damage, "ranged damage to", target.Name) end

	local attackerCharacter = attacker.Character
	if attackerCharacter and knockbackForce then
		applyKnockback(attackerCharacter, target, knockbackForce)
	end

	if ProcService then ProcService:ProcessHit(attacker, target, damage, isCrit) end
	local targetDied = not EnemyLib:IsAlive(target)
	if targetDied and ProcService then ProcService:ProcessKill(attacker, target) end
	return true, targetDied
end

local function processDamage(attacker: Player, target: Model, attackIndex: number, attackId: string): (boolean, boolean)
	if not attackId or attackId == "" then return false, false end
	local attackData = CombatConfig.Attacks[attackIndex]
	if not attackData then return false, false end
	return _applyDamage(attacker, target, attackId, attackData.Damage, attackData.Knockback, false)
end

local function onRequestAttack(player: Player, attackIndex: number, targetOrTargets: any, attackId: any)
	local targets = {}
	if typeof(targetOrTargets) == "Instance" then targets = { targetOrTargets }
	elseif type(targetOrTargets) == "table" then targets = targetOrTargets end

	local checkTarget = targets[1]
	local isValid, errorReason = validateAttack(player, attackIndex, checkTarget, attackId)
	if not isValid then return end

	for _, target in targets do
		local tValid, tError = validateAttack(player, attackIndex, target, attackId)
		if tValid then
			local didDamage, targetDied = processDamage(player, target, attackIndex, attackId)
			if didDamage then
				local attackData = CombatConfig.Attacks[attackIndex]
				local targetRoot = getTargetRoot(target)
				local hitPosition = targetRoot and targetRoot.Position or Vector3.zero

                -- OPTIMIZATION: Spatial Broadcast
				local hitConfirmedRemote = Remotes:GetEvent("HitConfirmed")
				if hitConfirmedRemote then
                    fireRelevantClients(hitConfirmedRemote, hitPosition, {
						Attacker = player,
						Target = target,
						AttackIndex = attackIndex,
						HitPosition = hitPosition,
						Hitstop = attackData.Hitstop,
						ScreenShake = attackData.ScreenShake,
						TargetDied = targetDied,
					})
				end

				if targetDied then
					local enemyDiedRemote = Remotes:GetEvent("EnemyDied")
					if enemyDiedRemote then
						fireRelevantClients(enemyDiedRemote, hitPosition, {
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

	local lastAttackId = playerLastAttackId[player]
	if attackId ~= lastAttackId then
		playerLastAttack[player] = tick()
		playerLastAttackId[player] = attackId
		if not playerComboState[player] then
			playerComboState[player] = { CurrentIndex = 0, LastAttackTime = 0 }
		end
		playerComboState[player].CurrentIndex = attackIndex
		playerComboState[player].LastAttackTime = tick()
	end

	-- OPTIMIZATION: Push to queue head
    activeAttacksTail += 1
    activeAttacks[activeAttacksTail] = { id = attackId, expiry = tick() + 1 }
end

local function validateRangedAttack(player: Player, targetModel: Model?, hitPosition: Vector3): (boolean, string?)
	local character = player.Character
	if not character then return false, "No character" end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return false, "Player dead" end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return false, "No root part" end

	local now = tick()
	local lastRangedAttack = playerLastRangedAttack[player] or 0
	local minInterval = (ClassConfig.Server.MinRangedInterval or 0.08) * 0.9
	if now - lastRangedAttack < minInterval then return false, "Ranged attack too fast" end

	if not targetModel then return true, nil end
	if not isTargetAlive(targetModel) then return false, "Target already dead" end
	local isEnemy = CollectionService:HasTag(targetModel, CombatConfig.Targeting.TargetTag)
	local isDummy = CollectionService:HasTag(targetModel, "TrainingDummy")
	if not isEnemy and not isDummy then return false, "Target is not an enemy" end

	local targetRoot = getTargetRoot(targetModel)
	if not targetRoot then return false, "Target has no root" end
	local maxRange = ClassConfig.Server.MaxRangedRange or 70
	local distance = (rootPart.Position - targetRoot.Position).Magnitude
	if distance > maxRange + 10 then return false, "Target too far for ranged attack" end
	return true, nil
end

local function processRangedDamage(attacker: Player, target: Model, hitPosition: Vector3, attackId: string): (boolean, boolean)
	local rangedData = ClassConfig.Gunner.RangedAttack
	if not rangedData then return false, false end
	return _applyDamage(attacker, target, attackId, rangedData.Damage, rangedData.Knockback, true)
end

local function onRequestRangedHit(player: Player, targetModel: Model?, hitPosition: Vector3, attackId: string)
	if targetModel ~= nil and typeof(targetModel) ~= "Instance" then return end
	if typeof(hitPosition) ~= "Vector3" then return end
	if typeof(attackId) ~= "string" then return end

	local isValid, errorReason = validateRangedAttack(player, targetModel, hitPosition)
	if not isValid then return end
	playerLastRangedAttack[player] = tick()
	if not targetModel then return end

	local didDamage, targetDied = processRangedDamage(player, targetModel, hitPosition, attackId)
	if not didDamage then return end

	local rangedData = ClassConfig.Gunner.RangedAttack
	local rangedHitConfirmedRemote = Remotes:GetEvent("RangedHitConfirmed")
	if rangedHitConfirmedRemote then
		fireRelevantClients(rangedHitConfirmedRemote, hitPosition, {
			Attacker = player,
			Target = targetModel,
			HitPosition = hitPosition,
			Hitstop = rangedData and rangedData.Hitstop or 0.01,
			ScreenShake = rangedData and rangedData.ScreenShake or 0.1,
			TargetDied = targetDied,
		})
	end

	if targetDied then
		local enemyDiedRemote = Remotes:GetEvent("EnemyDied")
		if enemyDiedRemote then
			fireRelevantClients(enemyDiedRemote, hitPosition, {
				Target = targetModel,
				Killer = player,
				Position = hitPosition,
			})
		end
		print("[CombatService]", player.Name, "killed", targetModel.Name, "(ranged)")
	end

	-- OPTIMIZATION: Push to queue head
    activeAttacksTail += 1
    activeAttacks[activeAttacksTail] = { id = attackId, expiry = tick() + 0.5 }
end

function CombatService:Init()
	print("[CombatService] Initializing...")
	Remotes:InitServer()
end

function CombatService:Start()
	print("[CombatService] Starting...")

	-- OPTIMIZATION: Efficient Queue Cleanup
	RunService.Heartbeat:Connect(function()
		local now = tick()
        -- Only process items that exist
		while activeAttacksHead <= activeAttacksTail do
			local entry = activeAttacks[activeAttacksHead]
			if now >= entry.expiry then
				attackHitTargets[entry.id] = nil
                activeAttacks[activeAttacksHead] = nil
                activeAttacksHead += 1
			else
				break
			end
		end

        -- Reset indices if empty to prevent number overflow (very long term)
        if activeAttacksHead > activeAttacksTail then
            activeAttacksHead = 1
            activeAttacksTail = 0
            activeAttacks = {}
        end
	end)

	ProcService = require(script.Parent.ProcService)

	local requestAttackRemote = Remotes:GetEvent("RequestAttack")
	if requestAttackRemote then requestAttackRemote.OnServerEvent:Connect(onRequestAttack) end

	local requestRangedHitRemote = Remotes:GetEvent("RequestRangedHit")
	if requestRangedHitRemote then requestRangedHitRemote.OnServerEvent:Connect(onRequestRangedHit) end

	Players.PlayerRemoving:Connect(function(player)
		playerLastAttack[player] = nil
		playerLastRangedAttack[player] = nil
		playerLastAttackId[player] = nil
		playerComboState[player] = nil
	end)

	print("[CombatService] Started successfully")
end

CombatService._processDamage = processDamage

return CombatService
