--[[
    CombatController.luau
    Main combat state machine handling:
    - 3-hit combo system with auto-attack on hold (Melee/Warrior)
    - Rapid-fire auto-aim ranged attacks (Ranged/Scrapper)
    - Hitbox spawning and collision detection
    - Integration with VFX (hitstop, screen shake, effects)
    - Server communication for damage
    - Movement speed reduction during attacks (melee only)
    - Dash canceling
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")

local Signal = require(ReplicatedStorage.Packages.Signal)
local CombatConfig = require(ReplicatedStorage.Shared.Config.CombatConfig)
local CharacterState = require(ReplicatedStorage.Shared.Enums.CharacterState)
local MovementConfig = require(ReplicatedStorage.Shared.Config.MovementConfig)
local StatLib = require(ReplicatedStorage.Shared.Lib.StatLib)
local CharacterLib = require(ReplicatedStorage.Shared.Lib.CharacterLib)
local EnemyLib = require(ReplicatedStorage.Shared.Lib.EnemyLib)

local CombatController = {}
CombatController.Name = "CombatController"

-- Config shortcuts
local ComboConfig = CombatConfig.Combo
local AttacksConfig = CombatConfig.Attacks

-- References (set in Init)
local LocalPlayer = Players.LocalPlayer
local InputController = nil
local MovementController = nil
local TargetingController = nil
local HitstopController = nil
local ScreenShakeController = nil
local CombatEffects = nil
local DashController = nil
local ClassController = nil
local ProjectileEffects = nil
local DamageNumbers = nil
local EnemyVFXController = nil

-- Object Pooling for VFX
local partPool = {}

local function getPartFromPool(name)
	if not partPool[name] then
		partPool[name] = {}
	end
	local part = table.remove(partPool[name])
	if not part then
		part = Instance.new("Part")
		part.Name = name
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
	end

	-- Increment generation to invalidate old tasks
	local gen = (part:GetAttribute("Generation") or 0) + 1
	part:SetAttribute("Generation", gen)

	return part, gen
end

local function returnPartToPool(part)
	part.Parent = nil
	local name = part.Name
	if not partPool[name] then
		partPool[name] = {}
	end
	table.insert(partPool[name], part)
end

-- Remote events (set in Start)
local Remotes = nil

-- Combat state (Melee)
local isAttacking = false
local currentComboHit = 0
local lastAttackTime = 0
local lastInputTime = 0 -- Added to track manual input timing
local attackEndTime = 0
local canQueueNextAttack = false
local queuedAttack = false

-- Configuration for input snappiness
local MIN_INPUT_INTERVAL = 0.15 -- Minimum time between manual clicks to prevent jitter

-- Combat state (Ranged)
local lastRangedFireTime = 0
local rangedAttackIdCounter = 0

-- Combat state (Flamethrower)
local isFlamethrowerActive = false
local lastFlamethrowerTick = 0
local flamethrowerTrack = nil

-- Hit tracking (prevent multi-hit on same enemy per swing)
local hitEnemiesThisSwing: { [Model]: boolean } = {}

-- Attack ID counter for unique attack identification
local attackIdCounter = 0

-- Original walk speed (to restore after attack)
local originalWalkSpeed = MovementConfig.WalkSpeed

-- Cached Params (Optimization)
local sharedOverlapParams = OverlapParams.new()
sharedOverlapParams.FilterType = Enum.RaycastFilterType.Exclude

local sharedRaycastParams = RaycastParams.new()
sharedRaycastParams.FilterType = Enum.RaycastFilterType.Exclude

-- Connections
local connections: { RBXScriptConnection } = {}
local hitboxConnection: RBXScriptConnection? = nil

-- Signals
CombatController.OnAttackStarted = Signal.new() -- Fires (comboHit, attackData)
CombatController.OnAttackEnded = Signal.new() -- Fires (comboHit)
CombatController.OnHit = Signal.new() -- Fires (target, comboHit, damage)
CombatController.OnComboReset = Signal.new() -- Fires when combo resets
CombatController.OnRangedFired = Signal.new() -- Fires (target, hitPosition, didHit)

-- Forward declaration (defined later in file)
local handleAttackInput

--[[
    Get character parts
]]
local function getCharacterParts(): (Model?, Humanoid?, BasePart?)
	local character = LocalPlayer.Character
	if not character then
		return nil, nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = CharacterLib:GetRootPart(character)

	return character, humanoid, rootPart
end

--[[
    Play attack animation (placeholder using humanoid animations)
]]
local function playAttackAnimation(humanoid: Humanoid, comboHit: number)
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	-- Use built-in tool animations as placeholder
	-- In production, replace with custom attack animations
	local animId = AttacksConfig[comboHit].AnimationId
	if not animId then
		-- Fallback to generic slash gesture
		-- We'll simulate with movement
		return nil
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = animId

	local track = animator:LoadAnimation(animation)
	track:Play()

	return track
end

--[[
    Create and check hitbox for this attack
    Uses the stored attack direction and target position to ensure hitbox hits the enemy
]]
local function createHitbox(
	rootPart: BasePart,
	attackData: any,
	attackDirection: Vector3?,
	targetPosition: Vector3?
): { Model }
	local hitTargets: { Model } = {}

	-- Use provided direction or fall back to character facing
	local direction = attackDirection or rootPart.CFrame.LookVector
	direction = Vector3.new(direction.X, 0, direction.Z) -- Flatten to horizontal
	if direction.Magnitude < 0.01 then
		direction = rootPart.CFrame.LookVector
		direction = Vector3.new(direction.X, 0, direction.Z).Unit
	else
		direction = direction.Unit
	end

	-- Get the offset values from config
	local offsetZ = attackData.HitboxOffset.Z -- Forward distance
	local offsetY = attackData.HitboxOffset.Y -- Vertical offset
	local offsetX = attackData.HitboxOffset.X -- Side offset

	-- Determine the base Y position for the hitbox
	-- If we have a target, use the target's Y position (so hitbox is at enemy height)
	-- Otherwise use player's Y position
	local baseY: number
	if targetPosition then
		-- Use target's height so we hit them even when jumping
		baseY = targetPosition.Y
	else
		baseY = rootPart.Position.Y
	end

	-- Calculate hitbox position:
	-- X/Z: start from player, move forward in attack direction
	-- Y: use target height (or player height if no target)
	local horizontalPos = Vector3.new(rootPart.Position.X, 0, rootPart.Position.Z)
		+ direction * offsetZ -- Forward
		+ direction:Cross(Vector3.new(0, 1, 0)) * offsetX -- Side

	local hitboxPosition = Vector3.new(horizontalPos.X, baseY + offsetY, horizontalPos.Z)

	-- Create CFrame at hitbox position, oriented to face attack direction
	local hitboxCFrame = CFrame.lookAt(hitboxPosition, hitboxPosition + direction)
	local hitboxSize = attackData.HitboxSize

	-- Use OverlapParams for spatial query
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = { LocalPlayer.Character }

	-- Get parts in hitbox
	local partsInBox = workspace:GetPartBoundsInBox(hitboxCFrame, hitboxSize, overlapParams)

	-- Find unique characters hit
	local charactersHit: { [Model]: boolean } = {}
	for _, part in partsInBox do
		local character = part:FindFirstAncestorOfClass("Model")
		if character and not charactersHit[character] then
			if EnemyLib:IsAlive(character) and character ~= LocalPlayer.Character then
				-- Check if not already hit this swing
				if not hitEnemiesThisSwing[character] then
					charactersHit[character] = true
					hitEnemiesThisSwing[character] = true
					table.insert(hitTargets, character)
				end
			end
		end
	end

	-- Visualize hitbox with hit/miss color feedback
	if CombatEffects then
		local didHit = #hitTargets > 0
		CombatEffects:VisualizeHitbox(hitboxCFrame, hitboxSize, attackData.HitDuration, didHit)
	end

	return hitTargets
end

--[[
    Process hits on targets
]]
local function processHits(hitTargets: { Model }, attackData: any, comboHit: number, attackId: string)
	if #hitTargets == 0 then
		return
	end

	local _, _, rootPart = getCharacterParts()
	if not rootPart then
		return
	end

	for _, target in hitTargets do
		local targetRoot = target:FindFirstChild("HumanoidRootPart") or target.PrimaryPart
		if targetRoot then
			-- Calculate hit position (between attacker and target)
			local hitPosition = (rootPart.Position + targetRoot.Position) / 2

			-- Spawn hit effects (fire-themed for Biker King)
			if CombatEffects then
				local isBikerKing = ClassController and ClassController:GetCurrentClass() == "BikerKing"
				if isBikerKing then
					CombatEffects:SpawnFireHitEffect(hitPosition, comboHit)
				end
				CombatEffects:SpawnHitEffects(hitPosition, nil, comboHit)
			end

			-- Spawn damage number (Client prediction)
			if DamageNumbers then
				-- Calculate predicted damage with items
				local damage = StatLib:GetStat(LocalPlayer, "Damage", attackData.Damage)
				local critChance = StatLib:GetStat(LocalPlayer, "CritChance", 0)
				local isCrit = math.random() <= critChance
				if isCrit then
					damage = damage * 2
				end

				-- Determine damage type based on combo hit and crit
				local damageType = "Normal"
				if isCrit then
					damageType = "Critical"
				elseif comboHit >= 3 then
					damageType = "Finisher"
				end
				DamageNumbers:SpawnOnCharacter(target, damage, damageType)
			end

			-- Apply knockback direction
			local knockbackDir = (targetRoot.Position - rootPart.Position).Unit
			knockbackDir = Vector3.new(knockbackDir.X, 0.3, knockbackDir.Z).Unit

			-- Send to server for damage
			-- Format: (attackIndex, targetModel, attackId)
			if Remotes and Remotes.RequestAttack then
				Remotes.RequestAttack:FireServer(comboHit, target, attackId)
			end

			-- Fire hit signal
			CombatController.OnHit:Fire(target, comboHit, attackData.Damage)
		end
	end

	-- Apply hitstop
	if HitstopController then
		HitstopController:ApplyHitstop(attackData.Hitstop, hitTargets)
	end

	-- Apply Instant Client-Side Hitstun VFX (Prediction)
	-- The cooldown in EnemyVFXController prevents double-application when server confirms
	if EnemyVFXController then
		for _, target in hitTargets do
			EnemyVFXController:PlayHitstun(target)
		end
	end

	-- Apply screen shake
	if ScreenShakeController then
		ScreenShakeController:ShakeFromHit(attackData)
	end
end

--[[
    Execute a single attack in the combo
]]
local function performAttack(comboHit: number)
	local character, humanoid, rootPart = getCharacterParts()
	if not character or not humanoid or not rootPart then
		return
	end

	-- Use class-specific attack data if available, otherwise fall back to default
	local attackData = AttacksConfig[comboHit]
	if ClassController and ClassController:IsClassSelected() then
		attackData = ClassController:GetMeleeAttackData(comboHit) or attackData
	end
	if not attackData then
		return
	end

	isAttacking = true
	currentComboHit = comboHit
	lastAttackTime = os.clock()
	attackEndTime = lastAttackTime + attackData.Duration
	canQueueNextAttack = false
	queuedAttack = false
	attackIdCounter += 1

	-- Notify server of attack start (allows sequence validation even on miss)
	local attackId = LocalPlayer.UserId .. "_" .. attackIdCounter
	if Remotes and Remotes.RequestAttack then
		Remotes.RequestAttack:FireServer(comboHit, nil, attackId)
	end

	table.clear(hitEnemiesThisSwing)

	-- Reduce movement speed during attack
	humanoid.WalkSpeed = originalWalkSpeed * ComboConfig.MovementSpeedMultiplier

	-- IMPORTANT: Refresh targeting before each attack to ensure we have latest target
	if TargetingController then
		TargetingController:RefreshTarget()
	end

	-- Determine attack direction - face the target if we have one
	local attackDir: Vector3
	local targetPos: Vector3? = nil

	if TargetingController and TargetingController:HasTarget() then
		targetPos = TargetingController:GetTargetPosition()
		local dirToTarget = TargetingController:GetDirectionToTarget()
		if dirToTarget and targetPos then
			attackDir = dirToTarget
			-- Rotate character to face target using MovementController
			if MovementController then
				MovementController:SetTargetRotationDuration(dirToTarget, attackData.Duration)
			end
		else
			attackDir = rootPart.CFrame.LookVector
			attackDir = Vector3.new(attackDir.X, 0, attackDir.Z).Unit
		end
	else
		-- No target - use current facing direction
		attackDir = rootPart.CFrame.LookVector
		attackDir = Vector3.new(attackDir.X, 0, attackDir.Z).Unit
	end

	-- Update state
	MovementController:SetState(CharacterState.Attacking)

	-- Fire signal
	CombatController.OnAttackStarted:Fire(comboHit, attackData)

	-- Play animation
	playAttackAnimation(humanoid, comboHit)

	-- Biker King: VOXEL FLAMETHROWER moved to Heartbeat loop (continuous)
	-- See handleFlamethrowerTick logic

	-- Capture the direction and target position at time of attack for the delayed hitbox
	local capturedDirection = attackDir
	local capturedTargetPos = targetPos

	-- Schedule hitbox activation
	task.delay(attackData.HitTime, function()
		if not isAttacking or currentComboHit ~= comboHit then
			return -- Attack was canceled
		end

		-- Re-get rootPart in case it changed
		local _, _, currentRootPart = getCharacterParts()
		if not currentRootPart then
			return
		end

		-- Get fresh target position if we still have a target (enemy might have moved)
		local currentTargetPos = capturedTargetPos
		if TargetingController and TargetingController:HasTarget() then
			local freshTargetPos = TargetingController:GetTargetPosition()
			if freshTargetPos then
				currentTargetPos = freshTargetPos
			end
		end

		-- Create hitbox using the CAPTURED direction but FRESH target position
		local hitTargets = createHitbox(currentRootPart, attackData, capturedDirection, currentTargetPos)
		processHits(hitTargets, attackData, comboHit, attackId)

		-- Allow queueing next attack after hit lands
		canQueueNextAttack = true

		-- Check if attack was queued while we were in hit window
		if queuedAttack then
			queuedAttack = false
			-- Will be processed in update loop
		end
	end)

	-- Schedule attack end
	task.delay(attackData.Duration, function()
		if currentComboHit ~= comboHit then
			return -- Already moved to next attack
		end

		isAttacking = false
		CombatController.OnAttackEnded:Fire(comboHit)

		-- Restore walk speed
		humanoid.WalkSpeed = originalWalkSpeed

		-- Check if we should continue combo
		if queuedAttack and comboHit < ComboConfig.MaxHits then
			performAttack(comboHit + 1)
		else
			-- Combo might continue if attack is held
			MovementController:SetState(CharacterState.Idle)
		end
	end)
end

--[[
    Start or continue the combo
]]
local function startAttack()
	if isAttacking then
		-- Queue next attack if allowed
		if canQueueNextAttack then
			queuedAttack = true
		end
		return
	end

	-- Check if combo should continue or reset
	local now = os.clock()
	local timeSinceLastAttack = now - lastAttackTime
	if timeSinceLastAttack > ComboConfig.ResetTime or currentComboHit >= ComboConfig.MaxHits then
		-- Reset combo
		currentComboHit = 0
		CombatController.OnComboReset:Fire()
	end

	-- Start next attack in combo
	performAttack(currentComboHit + 1)
end

--[[
    Cancel current attack (for dash cancel)
]]
local function cancelAttack()
	if not isAttacking then
		return
	end

	isAttacking = false
	canQueueNextAttack = false
	queuedAttack = false

	local _, humanoid = getCharacterParts()
	if humanoid then
		humanoid.WalkSpeed = originalWalkSpeed
	end

	CombatController.OnAttackEnded:Fire(currentComboHit)
end

--[[
    Handle attack input pressed
]]
local function onAttackPressed()
	-- FLAMETHROWER CHECK: Activate immediately (bypass click throttle)
	if ClassController and ClassController:IsClassSelected() then
		local at = ClassController:GetAttackType()
		if at == "Flamethrower" then
			isFlamethrowerActive = true
			return
		end
	end

	-- Determine input throttle based on class attack rate
	local interval = MIN_INPUT_INTERVAL

	-- Apply attack speed stat (Higher Rate = Lower Interval)
	local attackSpeedMult = StatLib:GetStat(LocalPlayer, "AttackRate", 1.0)

	if ClassController and ClassController:IsClassSelected() then
		local attackType = ClassController:GetAttackType()
		if attackType == "Ranged" then
			local rangedData = ClassController:GetRangedAttackData()
			if rangedData then
				interval = (rangedData.FireRate or interval) / attackSpeedMult
			end
		else
			-- Melee uses auto-attack interval as the throttle base
			interval = (ComboConfig.AutoAttackInterval or interval) / attackSpeedMult
		end
	end

	local now = os.clock()
	if now - lastInputTime < interval then
		return -- Throttle manual clicks to match class attack rate
	end
	lastInputTime = now

	handleAttackInput()
end

--[[
    Handle dash (cancel attack if configured)
]]
local function onDashStarted()
	if ComboConfig.CanDashCancel and isAttacking then
		cancelAttack()
	end
end

-- ============================================================================
-- RANGED ATTACK SYSTEM
-- ============================================================================

--[[
    Get muzzle position (where bullets spawn from)
    Uses right arm/hand position as approximation
]]
local function getMuzzlePosition(): Vector3?
	local character = LocalPlayer.Character
	if not character then
		return nil
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return nil
	end

	-- Try to find right arm for more accurate muzzle position
	local rightArm = character:FindFirstChild("Right Arm") or character:FindFirstChild("RightHand")
	if rightArm and rightArm:IsA("BasePart") then
		-- Offset forward from the hand
		return rightArm.Position + rootPart.CFrame.LookVector * 1.5
	end

	-- Fallback: offset from root part
	return rootPart.Position + rootPart.CFrame.LookVector * 2 + Vector3.new(0, 0.5, 0)
end

--[[
    Perform a ranged attack (raycast + VFX)
]]
local function performRangedAttack()
	local character, humanoid, rootPart = getCharacterParts()
	if not character or not humanoid or not rootPart then
		return
	end

	-- Get class data
	if not ClassController or not ClassController:IsClassSelected() then
		return
	end

	local rangedData = ClassController:GetRangedAttackData()
	if not rangedData then
		return
	end

	-- Check fire rate cooldown (affected by AttackRate stat)
	local attackSpeedMult = StatLib:GetStat(LocalPlayer, "AttackRate", 1.0)
	local cooldown = rangedData.FireRate / attackSpeedMult

	local now = os.clock()
	if now - lastRangedFireTime < cooldown then
		return
	end
	lastRangedFireTime = now
	rangedAttackIdCounter += 1

	-- Get muzzle position
	local muzzlePos = getMuzzlePosition()
	if not muzzlePos then
		return
	end

	-- Refresh targeting
	if TargetingController then
		TargetingController:RefreshTarget()
	end

	-- Determine aim direction
	local aimDirection: Vector3
	local targetPosition: Vector3? = nil

	if TargetingController and TargetingController:HasTarget() then
		targetPosition = TargetingController:GetTargetPosition()
		if targetPosition then
			aimDirection = (targetPosition - muzzlePos).Unit

			-- Rotate character to face target
			local dirToTarget = TargetingController:GetDirectionToTarget()
			if dirToTarget and MovementController then
				-- Override for 0.5s so rapid fire keeps you facing the enemy smoothly
				MovementController:SetTargetRotationDuration(dirToTarget, 0.5)
			end
		else
			-- Fallback if target lost mid-frame
			local camLook = Workspace.CurrentCamera.CFrame.LookVector
			aimDirection = Vector3.new(camLook.X, 0, camLook.Z).Unit

			if MovementController then
				MovementController:SetTargetRotationDuration(aimDirection, 0.5)
			end
		end
	else
		-- No target - shoot forward based on camera
		local camLook = Workspace.CurrentCamera.CFrame.LookVector
		aimDirection = Vector3.new(camLook.X, 0, camLook.Z).Unit

		if MovementController then
			MovementController:SetTargetRotationDuration(aimDirection, 0.5)
		end
	end

	-- Apply spread
	local spread = rangedData.Spread or 0
	if spread > 0 then
		local spreadRad = math.rad(spread)
		local randomAngle = math.random() * math.pi * 2
		local randomSpread = math.random() * spreadRad
		local right = aimDirection:Cross(Vector3.new(0, 1, 0)).Unit
		local up = right:Cross(aimDirection).Unit
		aimDirection = (aimDirection + right * math.sin(randomAngle) * math.sin(randomSpread) + up * math.cos(
			randomAngle
		) * math.sin(randomSpread)).Unit
	end

	-- Raycast
	sharedRaycastParams.FilterDescendantsInstances = { character }

	local maxRange = rangedData.Range or 60
	local rayResult = workspace:Raycast(muzzlePos, aimDirection * maxRange, sharedRaycastParams)

	local hitPosition: Vector3
	local hitNormal: Vector3?
	local hitTarget: Model? = nil
	local didHit = false

	if rayResult then
		hitPosition = rayResult.Position
		hitNormal = rayResult.Normal

		-- Check if we hit a valid target
		local hitPart = rayResult.Instance
		if hitPart then
			local hitModel = hitPart:FindFirstAncestorOfClass("Model")
			if hitModel then
				if EnemyLib:IsAlive(hitModel) and hitModel ~= character then
					hitTarget = hitModel
					didHit = true
				end
			end
		end
	else
		-- No hit - bullet travels to max range
		hitPosition = muzzlePos + aimDirection * maxRange
	end

	-- Play VFX
	if ProjectileEffects then
		if didHit then
			ProjectileEffects:PlayRangedHitEffects(muzzlePos, hitPosition, hitNormal, rangedData)
		else
			ProjectileEffects:PlayRangedMissEffects(muzzlePos, hitPosition, rangedData)
		end
	end

	-- Send hit to server if we hit something
	if didHit and hitTarget then
		if Remotes and Remotes.RequestRangedHit then
			local attackId = LocalPlayer.UserId .. "_R_" .. rangedAttackIdCounter
			local heatCharge = LocalPlayer:GetAttribute("HeatCharge") or 0
			local isShredShot = heatCharge >= 100
			Remotes.RequestRangedHit:FireServer(hitTarget, hitPosition, attackId, isShredShot)

			if isShredShot then
				-- Reset heat and add a 2.5 second cooldown before it can build again
				LocalPlayer:SetAttribute("HeatCharge", 0)
				LocalPlayer:SetAttribute("HeatResetTime", tick() + 2.5)
			end

			-- Light hitstop and screen shake for feedback
			if HitstopController and rangedData.Hitstop then
				HitstopController:ApplyHitstop(rangedData.Hitstop, { hitTarget })
			end
			if ScreenShakeController and rangedData.ScreenShake then
				ScreenShakeController:Shake(rangedData.ScreenShake, 0.1)
			end

			-- Spawn damage number for ranged hit (Client prediction)
			if DamageNumbers then
				local baseDamage = rangedData.Damage or 10
				local damage = StatLib:GetStat(LocalPlayer, "Damage", baseDamage)
				local critChance = StatLib:GetStat(LocalPlayer, "CritChance", 0)
				local isCrit = math.random() <= critChance
				if isCrit then
					damage = damage * 2
				end

				local damageType = isCrit and "Critical" or "Normal"
				DamageNumbers:SpawnOnCharacter(hitTarget, damage, damageType)
			end
		end
	end

	-- Fire signal
	CombatController.OnRangedFired:Fire(hitTarget, hitPosition, didHit)
end

--[[
    Handle attack input for current class
]]
function handleAttackInput()
	-- Check if class is selected
	if ClassController and ClassController:IsClassSelected() then
		local attackType = ClassController:GetAttackType()
		if attackType == "Ranged" then
			performRangedAttack()
			return
		end
	end

	-- Default to melee
	startAttack()
end

--[[

-- Public API --

--[[
    Check if currently attacking
]]
function CombatController:IsAttacking(): boolean
	return isAttacking
end

--[[
    Get current combo hit number (1-3)
]]
function CombatController:GetCurrentComboHit(): number
	return currentComboHit
end

--[[
    Check if can attack
]]
function CombatController:CanAttack(): boolean
	local _, humanoid = getCharacterParts()
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	return true
end

--[[
    Force cancel attack
]]
function CombatController:CancelAttack()
	cancelAttack()
end

--[[
    Reset combo
]]
function CombatController:ResetCombo()
	currentComboHit = 0
	isAttacking = false
	queuedAttack = false
	CombatController.OnComboReset:Fire()
end

--[[
    Initialize the controller
]]
function CombatController:Init()
	-- Get references to other controllers
	InputController = require(script.Parent.InputController)
	MovementController = require(script.Parent.Parent.Features.Movement.MovementController)

	-- VFX controllers (may not be in Core folder)
	local function tryRequire(path)
		local success, result = pcall(function()
			return require(path)
		end)
		return success and result or nil
	end

	TargetingController = tryRequire(script.Parent.Parent.Features.Combat.TargetingController)
	HitstopController = tryRequire(script.Parent.Parent.VFX.HitstopController)
	ScreenShakeController = tryRequire(script.Parent.Parent.VFX.ScreenShakeController)
	CombatEffects = tryRequire(script.Parent.Parent.VFX.CombatEffects)
	DashController = tryRequire(script.Parent.DashController)

	-- Class system controllers
	ClassController = tryRequire(script.Parent.Parent.Features.Class.ClassController)
	ProjectileEffects = tryRequire(script.Parent.Parent.VFX.ProjectileEffects)
	DamageNumbers = tryRequire(script.Parent.Parent.VFX.DamageNumbers)
	EnemyVFXController = tryRequire(script.Parent.EnemyVFXController)

	-- Debug display - DISABLED for now to reduce spam
	-- local DebugDisplay = tryRequire(script.Parent.Parent.UI.HUD.DebugDisplay)
	-- if DebugDisplay then
	--     DebugDisplay.new()
	--     _G.DebugDisplay = DebugDisplay
	-- end

	print("[CombatController] Initialized")
end

--[[
    Start the controller
]]
--[[
    Process continuous flamethrower logic (visuals + damage)
]]
local function handleFlamethrowerTick(dt)
	-- 1. Input Check
	if not InputController:IsAttackHeld() then
		isFlamethrowerActive = false
		local _, humanoid = getCharacterParts()
		if humanoid then
			-- Restore normal speed
			local baseSpeed = StatLib:GetStat(LocalPlayer, "WalkSpeed", MovementConfig.WalkSpeed)
			humanoid.WalkSpeed = baseSpeed
		end

		-- Destroy light
		local char = LocalPlayer.Character
		if char and char:FindFirstChild("HumanoidRootPart") then
			local light = char.HumanoidRootPart:FindFirstChild("FlamethrowerLight")
			if light then
				light:Destroy()
			end
		end

		-- Stop Animation
		if flamethrowerTrack then
			flamethrowerTrack:Stop(0.2)
			flamethrowerTrack:Destroy()
			flamethrowerTrack = nil
		end
		return
	end

	-- 2. Config Check
	local classData = ClassController:GetClassData("BikerKing")
	local ftData = classData and classData.FlamethrowerAttack
	if not ftData then
		return
	end

	local char, humanoid, rootPart = getCharacterParts()
	if not char or not humanoid or not rootPart then
		return
	end

	-- 2.5 Animation
	if not flamethrowerTrack then
		local animId = ftData.AnimationId
		if not animId or animId == "rbxassetid://0" then
			animId = "rbxassetid://507768375" -- Fallback: ToolNone
		end

		local anim = Instance.new("Animation")
		anim.AnimationId = animId
		anim.Name = "FlamethrowerHold"

		local animator = humanoid:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = humanoid
		end

		flamethrowerTrack = animator:LoadAnimation(anim)
		flamethrowerTrack.Priority = Enum.AnimationPriority.Action
		flamethrowerTrack.Looped = true
		flamethrowerTrack:Play(0.2)
	end

	if flamethrowerTrack and not flamethrowerTrack.IsPlaying then
		flamethrowerTrack:Play(0.1)
	end

	-- 3. Rotation (Snap to target for aiming)
	if TargetingController and TargetingController:HasTarget() then
		local dirToTarget = TargetingController:GetDirectionToTarget()
		if dirToTarget then
			local targetCFrame = CFrame.lookAt(rootPart.Position, rootPart.Position + dirToTarget)
			rootPart.CFrame = CFrame.new(rootPart.Position) * targetCFrame.Rotation
		end
	end

	-- 4. Movement Slow
	local baseSpeed = StatLib:GetStat(LocalPlayer, "WalkSpeed", MovementConfig.WalkSpeed)
	humanoid.WalkSpeed = baseSpeed * (ftData.WalkSpeedMultiplier or 0.6)

	-- 5. Visuals (STYLIZED ANIME FLAME - COHESIVE & TURBULENT)
	local spawnOffset = CFrame.new(2.5, 0.5, -3)
	local originCFrame = rootPart.CFrame * spawnOffset
	local forwardDir = originCFrame.LookVector
	local rightDir = originCFrame.RightVector
	local upDir = originCFrame.UpVector

	-- A) MAIN FLAME BLOCKS
	if ftData.VoxelEnabled then
		for _ = 1, (ftData.VoxelCountPerFrame or 6) do
			-- Subtle Turbulence Path (reduced from 0.4 to 0.15)
			local angle = tick() * 12 + (math.random() * 2)
			local turbX = math.sin(angle) * 0.15
			local turbY = math.cos(angle * 0.7) * 0.15

			local spreadX = (math.random() - 0.5) * 0.4 + turbX
			local spreadY = (math.random() - 0.5) * 0.4 + turbY

			local dir = (forwardDir + rightDir * spreadX + upDir * spreadY).Unit
			local speed = (ftData.FlameSpeed or 45) * (0.85 + math.random() * 0.4)
			local lifetime = 0.6 + math.random() * 0.3

			local startSize = ftData.CubeStartSize or 1.0
			local endSize = ftData.CubeEndSize or 5.0

			local cube, gen = getPartFromPool("AnimeFire")
			cube.Material = Enum.Material.Neon
			cube.Size = Vector3.new(startSize, startSize, startSize)

			-- High Intensity Start Color (Bright Yellow-White)
			cube.Color = Color3.fromRGB(255, 255, 200)
			cube.Transparency = 0

			local rot = CFrame.Angles(math.random() * 6, math.random() * 6, math.random() * 6)
			cube.CFrame = originCFrame * rot
			cube.Parent = workspace.Terrain
			task.delay(lifetime + 0.1, returnPartToPool, cube)

			local travelDist = speed * lifetime
			local endPos = originCFrame.Position + dir * travelDist + Vector3.new(0, 4, 0) -- Reduced rise

			-- Smoother Expansion (Quad instead of Back)
			local tweenInfo = TweenInfo.new(lifetime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			local targetRot = rot * CFrame.Angles(math.random() * 3, math.random() * 3, math.random() * 3)

			local tween = TweenService:Create(cube, tweenInfo, {
				CFrame = CFrame.new(endPos) * targetRot,
				Size = Vector3.new(endSize, endSize, endSize),
				Transparency = 1,
			})
			tween:Play()

			-- Stylized Flame Palette (Yellow -> Vibrant Orange -> Warm Red -> Dark Smoke)
			task.spawn(function()
				task.wait(lifetime * 0.1)
				if cube:GetAttribute("Generation") ~= gen or not cube.Parent then
					return
				end
				TweenService:Create(cube, TweenInfo.new(lifetime * 0.2), { Color = Color3.fromRGB(255, 180, 50) })
					:Play() -- Warm Orange
				task.wait(lifetime * 0.2)
				if cube:GetAttribute("Generation") ~= gen or not cube.Parent then
					return
				end
				TweenService:Create(cube, TweenInfo.new(lifetime * 0.3), { Color = Color3.fromRGB(200, 60, 20) }):Play() -- Burnt Red
				task.wait(lifetime * 0.2)
				if cube:GetAttribute("Generation") ~= gen or not cube.Parent then
					return
				end
				TweenService:Create(cube, TweenInfo.new(lifetime * 0.2), { Color = Color3.fromRGB(60, 60, 60) }):Play() -- Smoke Grey
			end)
		end
	end

	-- B) SPARK SPRAY (Hyper-fast detached embers)
	if ftData.StraysEnabled then
		for _ = 1, (ftData.StrayCountPerFrame or 3) do
			local spreadAmount = ftData.StraySpread or 1.0
			local spreadX = (math.random() - 0.5) * spreadAmount
			local spreadY = (math.random() - 0.5) * spreadAmount

			local dir = (forwardDir + rightDir * spreadX + upDir * spreadY).Unit
			local speed = (ftData.StraySpeed or 110) * (0.7 + math.random() * 0.6)
			local lifetime = (ftData.StrayLifetime or 0.35)

			local spark = getPartFromPool("FireSpark")
			spark.Material = Enum.Material.Neon
			spark.Size = Vector3.new(0.2, 0.2, 0.2)
			spark.Color = Color3.fromRGB(255, 255, 180)
			spark.Transparency = 0
			spark.CFrame = originCFrame
			spark.Parent = workspace.Terrain
			task.delay(lifetime + 0.1, returnPartToPool, spark)

			local endPos = originCFrame.Position + dir * (speed * lifetime)

			TweenService
				:Create(spark, TweenInfo.new(lifetime, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {
					Position = endPos,
					Size = Vector3.new(0, 0, 0),
					Transparency = 0.5,
				})
				:Play()
		end
	end

	-- Light
	local light = rootPart:FindFirstChild("FlamethrowerLight")
	if not light then
		light = Instance.new("PointLight")
		light.Name = "FlamethrowerLight"
		light.Parent = rootPart
	end
	light.Brightness = (ftData.LightBrightness or 6) + math.random() * 2
	light.Range = (ftData.LightRange or 25) + math.random() * 4
	light.Color = Color3.fromRGB(255, 140, 40)

	-- 6. Damage (Per Tick)
	local now = os.clock()
	if now - lastFlamethrowerTick >= ftData.TickRate then
		lastFlamethrowerTick = now

		local range = ftData.Range or 35
		local angleCos = math.cos(math.rad((ftData.ConeAngle or 45) / 2))

		local overlapParams = OverlapParams.new()
		overlapParams.FilterType = Enum.RaycastFilterType.Exclude
		overlapParams.FilterDescendantsInstances = { char }

		local candidates = workspace:GetPartBoundsInRadius(rootPart.Position, range, overlapParams)
		local hits = {}

		local forward = rootPart.CFrame.LookVector

		for _, part in candidates do
			local model = part:FindFirstAncestorOfClass("Model")
			if model and model ~= char and not hits[model] then
				if EnemyLib:IsAlive(model) then
					local dist = (part.Position - rootPart.Position).Magnitude
					if dist < 6 then
						hits[model] = true
					else
						local dirToTarget = (part.Position - rootPart.Position).Unit
						if forward:Dot(dirToTarget) >= angleCos then
							hits[model] = true
						end
					end
				end
			end
		end

		local hitList = {}
		for enemy, _ in hits do
			table.insert(hitList, enemy)
			if CombatEffects then
				CombatEffects:SpawnHitEffects(enemy.PrimaryPart.Position, nil, 1)
			end
		end

		if #hitList > 0 then
			if Remotes.RequestAttack then
				Remotes.RequestAttack:FireServer(1, hitList, { IsFlamethrower = true })
			end
		end
	end
end

--[[
    Heartbeat handler
    Handles auto-attacks for Melee, Ranged, and Flamethrower
]]
local function onHeartbeat(dt: number)
	if isFlamethrowerActive then
		handleFlamethrowerTick(dt)
	end

	-- Check attack type based on class
	local attackType = nil
	if ClassController and ClassController:IsClassSelected() then
		attackType = ClassController:GetAttackType()
	end

	if attackType == "Ranged" then
		-- Ranged: continuous fire while holding
		if InputController:IsAttackHeld() then
			local success, err = pcall(performRangedAttack)
			if not success then
				warn("[CombatController] Ranged attack error:", err)
			end
		end
	elseif attackType == "Flamethrower" then
		-- Flamethrower is handled by handleFlamethrowerTick above if isFlamethrowerActive is true
	else
		-- Melee/Default: auto-attack while holding attack button
		if InputController:IsAttackHeld() and not isAttacking and not isFlamethrowerActive then
			local timeSinceLastAttack = os.clock() - attackEndTime
			local attackSpeedMult = StatLib:GetStat(LocalPlayer, "AttackRate", 1.0)
			local autoInterval = ComboConfig.AutoAttackInterval / attackSpeedMult

			if timeSinceLastAttack >= autoInterval then
				startAttack()
			end
		end

		-- Check combo timeout
		if not isAttacking and currentComboHit > 0 then
			local timeSinceLastAttack = os.clock() - lastAttackTime
			if timeSinceLastAttack > ComboConfig.ResetTime then
				currentComboHit = 0
				CombatController.OnComboReset:Fire()
			end
		end
	end
end

--[[
    Start the controller
]]
function CombatController:Start()
	-- Get remotes
	local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if remotesFolder then
		Remotes = {
			RequestAttack = remotesFolder:FindFirstChild("RequestAttack"),
			HitConfirmed = remotesFolder:FindFirstChild("HitConfirmed"),
			RequestRangedHit = remotesFolder:FindFirstChild("RequestRangedHit"),
			RangedHitConfirmed = remotesFolder:FindFirstChild("RangedHitConfirmed"),
		}
	else
		warn("[CombatController] Remotes folder not found - damage will be client-only")
	end

	-- Connect Events
	if InputController then
		table.insert(connections, InputController.OnAttackPressed:Connect(onAttackPressed))
	end

	if DashController then
		table.insert(connections, DashController.OnDashStarted:Connect(onDashStarted))
	end

	table.insert(connections, RunService.Heartbeat:Connect(onHeartbeat))

	table.insert(
		connections,
		LocalPlayer.CharacterAdded:Connect(function(character)
			isAttacking = false
			isFlamethrowerActive = false
			currentComboHit = 0
			queuedAttack = false
			lastRangedFireTime = 0
			table.clear(hitEnemiesThisSwing)

			local humanoid = character:WaitForChild("Humanoid", 5)
			if humanoid then
				originalWalkSpeed = humanoid.WalkSpeed
			end
		end)
	)

	if Remotes and Remotes.HitConfirmed then
		table.insert(
			connections,
			Remotes.HitConfirmed.OnClientEvent:Connect(function(hitData)
				if hitData.Attacker == LocalPlayer and HitstopController and hitData.Hitstop then
					-- Hitstop logic
				end
				if CombatEffects and hitData.HitPosition then
					if hitData.Attacker and hitData.Attacker.Character then
						local attackerClass = hitData.Attacker:GetAttribute("Class")
						if attackerClass == "BikerKing" then
							CombatEffects:SpawnFireHitEffect(hitData.HitPosition, hitData.AttackIndex)
						end
					end
					CombatEffects:SpawnHitEffects(hitData.HitPosition, nil, hitData.AttackIndex)
				end
			end)
		)
	end

	if Remotes and Remotes.ShowDamageNumber then
		table.insert(
			connections,
			Remotes.ShowDamageNumber.OnClientEvent:Connect(function(target, damage, damageType)
				if DamageNumbers then
					DamageNumbers:SpawnOnCharacter(target, damage, damageType)
				end
			end)
		)
	end

	print("[CombatController] Started")
end

--[[
    Cleanup
]]
function CombatController:Destroy()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)

	if hitboxConnection then
		hitboxConnection:Disconnect()
		hitboxConnection = nil
	end
end

return CombatController
