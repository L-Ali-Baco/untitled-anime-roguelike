--[[
    CombatController.luau
    Main combat state machine.
    Refactored to use VFXPool and VFXSystem for Flamethrower optimization.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Signal = require(ReplicatedStorage.Packages.Signal)
local CombatConfig = require(ReplicatedStorage.Shared.Config.CombatConfig)
local CharacterState = require(ReplicatedStorage.Shared.Enums.CharacterState)
local MovementConfig = require(ReplicatedStorage.Shared.Config.MovementConfig)
local StatLib = require(ReplicatedStorage.Shared.Lib.StatLib)
local CharacterLib = require(ReplicatedStorage.Shared.Lib.CharacterLib)
local EnemyLib = require(ReplicatedStorage.Shared.Lib.EnemyLib)

-- VFX Optimization Modules
local VFXPool = require(script.Parent.Parent.VFX.VFXPool)
local VFXSystem = require(script.Parent.Parent.VFX.VFXSystem)

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

-- Remote events (set in Start)
local Remotes = nil

-- Combat state (Melee)
local isAttacking = false
local currentComboHit = 0
local lastAttackTime = 0
local lastInputTime = 0
local attackEndTime = 0
local canQueueNextAttack = false
local queuedAttack = false

local MIN_INPUT_INTERVAL = 0.15

-- Combat state (Ranged)
local lastRangedFireTime = 0
local rangedAttackIdCounter = 0

-- Combat state (Flamethrower)
local isFlamethrowerActive = false
local lastFlamethrowerTick = 0
local flamethrowerTrack = nil

-- Hit tracking
local hitEnemiesThisSwing: { [Model]: boolean } = {}
local attackIdCounter = 0
local currentAttackDirection: Vector3? = nil
local originalWalkSpeed = MovementConfig.WalkSpeed

local sharedOverlapParams = OverlapParams.new()
sharedOverlapParams.FilterType = Enum.RaycastFilterType.Exclude

local sharedRaycastParams = RaycastParams.new()
sharedRaycastParams.FilterType = Enum.RaycastFilterType.Exclude

local connections: { RBXScriptConnection } = {}
local hitboxConnection: RBXScriptConnection? = nil

CombatController.OnAttackStarted = Signal.new()
CombatController.OnAttackEnded = Signal.new()
CombatController.OnHit = Signal.new()
CombatController.OnComboReset = Signal.new()
CombatController.OnRangedFired = Signal.new()

-- Templates
local function getAnimeFireTemplate()
	local p = Instance.new("Part")
	p.Name = "AnimeFire"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	return p
end

local function getFireSparkTemplate()
	local p = Instance.new("Part")
	p.Name = "FireSpark"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	return p
end

-- Forward declaration
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
    Play attack animation (placeholder)
]]
local function playAttackAnimation(humanoid: Humanoid, comboHit: number)
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local animId = AttacksConfig[comboHit].AnimationId
	if not animId then return nil end

	local animation = Instance.new("Animation")
	animation.AnimationId = animId

	local track = animator:LoadAnimation(animation)
	track:Play()

	return track
end

--[[
    Create and check hitbox
]]
local function createHitbox(rootPart, attackData, attackDirection, targetPosition)
	local hitTargets = {}

	local direction = attackDirection or rootPart.CFrame.LookVector
	direction = Vector3.new(direction.X, 0, direction.Z)
	if direction.Magnitude < 0.01 then
		direction = rootPart.CFrame.LookVector
		direction = Vector3.new(direction.X, 0, direction.Z).Unit
	else
		direction = direction.Unit
	end

	local offsetZ = attackData.HitboxOffset.Z
	local offsetY = attackData.HitboxOffset.Y
	local offsetX = attackData.HitboxOffset.X

	local baseY
	if targetPosition then
		baseY = targetPosition.Y
	else
		baseY = rootPart.Position.Y
	end

	local horizontalPos = Vector3.new(rootPart.Position.X, 0, rootPart.Position.Z)
		+ direction * offsetZ
		+ direction:Cross(Vector3.new(0, 1, 0)) * offsetX

	local hitboxPosition = Vector3.new(horizontalPos.X, baseY + offsetY, horizontalPos.Z)
	local hitboxCFrame = CFrame.lookAt(hitboxPosition, hitboxPosition + direction)
	local hitboxSize = attackData.HitboxSize

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = { LocalPlayer.Character }

	local partsInBox = workspace:GetPartBoundsInBox(hitboxCFrame, hitboxSize, overlapParams)
	local charactersHit = {}

	for _, part in partsInBox do
		local character = part:FindFirstAncestorOfClass("Model")
		if character and not charactersHit[character] then
			if EnemyLib:IsAlive(character) and character ~= LocalPlayer.Character then
				if not hitEnemiesThisSwing[character] then
					charactersHit[character] = true
					hitEnemiesThisSwing[character] = true
					table.insert(hitTargets, character)
				end
			end
		end
	end

	if CombatEffects then
		local didHit = #hitTargets > 0
		CombatEffects:VisualizeHitbox(hitboxCFrame, hitboxSize, attackData.HitDuration, didHit)
	end

	return hitTargets
end

--[[
    Process hits
]]
local function processHits(hitTargets, attackData, comboHit, attackId)
	if #hitTargets == 0 then return end
	local character, humanoid, rootPart = getCharacterParts()
	if not rootPart then return end

	for _, target in hitTargets do
		local targetRoot = target:FindFirstChild("HumanoidRootPart") or target.PrimaryPart
		if targetRoot then
			local hitPosition = (rootPart.Position + targetRoot.Position) / 2

			if CombatEffects then
				local isBikerKing = ClassController and ClassController:GetCurrentClass() == "BikerKing"
				if isBikerKing then
					CombatEffects:SpawnFireHitEffect(hitPosition, comboHit)
				end
				CombatEffects:SpawnHitEffects(hitPosition, nil, comboHit)
			end

			if DamageNumbers then
				local damage = StatLib:GetStat(LocalPlayer, "Damage", attackData.Damage)
				local critChance = StatLib:GetStat(LocalPlayer, "CritChance", 0)
				local isCrit = math.random() <= critChance
				if isCrit then damage = damage * 2 end

				local damageType = "Normal"
				if isCrit then damageType = "Critical"
				elseif comboHit >= 3 then damageType = "Finisher" end
				DamageNumbers:SpawnOnCharacter(target, damage, damageType)
			end

			if Remotes and Remotes.RequestAttack then
				Remotes.RequestAttack:FireServer(comboHit, target, attackId)
			end

			CombatController.OnHit:Fire(target, comboHit, attackData.Damage)
		end
	end

	if HitstopController then
		HitstopController:ApplyHitstop(attackData.Hitstop, hitTargets)
	end

	if EnemyVFXController then
		for _, target in hitTargets do
			EnemyVFXController:PlayHitstun(target)
		end
	end

	if ScreenShakeController then
		ScreenShakeController:ShakeFromHit(attackData)
	end
end

--[[
    Perform Attack
]]
local function performAttack(comboHit: number)
	local character, humanoid, rootPart = getCharacterParts()
	if not character or not humanoid or not rootPart then return end

	local attackData = AttacksConfig[comboHit]
	if ClassController and ClassController:IsClassSelected() then
		attackData = ClassController:GetMeleeAttackData(comboHit) or attackData
	end
	if not attackData then return end

	isAttacking = true
	currentComboHit = comboHit
	lastAttackTime = os.clock()
	attackEndTime = lastAttackTime + attackData.Duration
	canQueueNextAttack = false
	queuedAttack = false
	attackIdCounter += 1

	local attackId = LocalPlayer.UserId .. "_" .. attackIdCounter
	if Remotes and Remotes.RequestAttack then
		Remotes.RequestAttack:FireServer(comboHit, nil, attackId)
	end

	table.clear(hitEnemiesThisSwing)
	humanoid.WalkSpeed = originalWalkSpeed * ComboConfig.MovementSpeedMultiplier

	if TargetingController then TargetingController:RefreshTarget() end

	local attackDir
	local targetPos = nil

	if TargetingController and TargetingController:HasTarget() then
		targetPos = TargetingController:GetTargetPosition()
		local dirToTarget = TargetingController:GetDirectionToTarget()
		if dirToTarget and targetPos then
			attackDir = dirToTarget
			local targetCFrame = CFrame.lookAt(rootPart.Position, rootPart.Position + dirToTarget)
			rootPart.CFrame = CFrame.new(rootPart.Position) * targetCFrame.Rotation
		else
			attackDir = rootPart.CFrame.LookVector
			attackDir = Vector3.new(attackDir.X, 0, attackDir.Z).Unit
		end
	else
		attackDir = rootPart.CFrame.LookVector
		attackDir = Vector3.new(attackDir.X, 0, attackDir.Z).Unit
	end

	currentAttackDirection = attackDir
	MovementController:SetState(CharacterState.Attacking)
	CombatController.OnAttackStarted:Fire(comboHit, attackData)
	playAttackAnimation(humanoid, comboHit)

	local capturedDirection = attackDir
	local capturedTargetPos = targetPos

	task.delay(attackData.HitTime, function()
		if not isAttacking or currentComboHit ~= comboHit then return end
		local _, _, currentRootPart = getCharacterParts()
		if not currentRootPart then return end

		local currentTargetPos = capturedTargetPos
		if TargetingController and TargetingController:HasTarget() then
			local freshTargetPos = TargetingController:GetTargetPosition()
			if freshTargetPos then currentTargetPos = freshTargetPos end
		end

		local hitTargets = createHitbox(currentRootPart, attackData, capturedDirection, currentTargetPos)
		processHits(hitTargets, attackData, comboHit, attackId)
		canQueueNextAttack = true
		if queuedAttack then queuedAttack = false end
	end)

	task.delay(attackData.Duration, function()
		if currentComboHit ~= comboHit then return end
		isAttacking = false
		currentAttackDirection = nil
		CombatController.OnAttackEnded:Fire(comboHit)
		humanoid.WalkSpeed = originalWalkSpeed
		if queuedAttack and comboHit < ComboConfig.MaxHits then
			performAttack(comboHit + 1)
		else
			MovementController:SetState(CharacterState.Idle)
		end
	end)
end

local function startAttack()
	if isAttacking then
		if canQueueNextAttack then queuedAttack = true end
		return
	end
	local now = os.clock()
	if now - lastAttackTime > ComboConfig.ResetTime or currentComboHit >= ComboConfig.MaxHits then
		currentComboHit = 0
		CombatController.OnComboReset:Fire()
	end
	performAttack(currentComboHit + 1)
end

local function cancelAttack()
	if not isAttacking then return end
	isAttacking = false
	canQueueNextAttack = false
	queuedAttack = false
	local _, humanoid = getCharacterParts()
	if humanoid then humanoid.WalkSpeed = originalWalkSpeed end
	CombatController.OnAttackEnded:Fire(currentComboHit)
end

local function onAttackPressed()
	if ClassController and ClassController:IsClassSelected() then
		local at = ClassController:GetAttackType()
		if at == "Flamethrower" then
			isFlamethrowerActive = true
			return
		end
	end

	local interval = MIN_INPUT_INTERVAL
	local attackSpeedMult = StatLib:GetStat(LocalPlayer, "AttackRate", 1.0)

	if ClassController and ClassController:IsClassSelected() then
		local attackType = ClassController:GetAttackType()
		if attackType == "Ranged" then
			local rangedData = ClassController:GetRangedAttackData()
			if rangedData then
				interval = (rangedData.FireRate or interval) / attackSpeedMult
			end
		else
			interval = (ComboConfig.AutoAttackInterval or interval) / attackSpeedMult
		end
	end

	local now = os.clock()
	if now - lastInputTime < interval then return end
	lastInputTime = now
	handleAttackInput()
end

local function onDashStarted()
	if ComboConfig.CanDashCancel and isAttacking then
		cancelAttack()
	end
end

-- ============================================================================
-- RANGED
-- ============================================================================

local function getMuzzlePosition()
	local character = LocalPlayer.Character
	if not character then return nil end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return nil end
	local rightArm = character:FindFirstChild("Right Arm") or character:FindFirstChild("RightHand")
	if rightArm and rightArm:IsA("BasePart") then
		return rightArm.Position + rootPart.CFrame.LookVector * 1.5
	end
	return rootPart.Position + rootPart.CFrame.LookVector * 2 + Vector3.new(0, 0.5, 0)
end

local function performRangedAttack()
	local character, humanoid, rootPart = getCharacterParts()
	if not character or not humanoid or not rootPart then return end
	if not ClassController or not ClassController:IsClassSelected() then return end
	local rangedData = ClassController:GetRangedAttackData()
	if not rangedData then return end

	local attackSpeedMult = StatLib:GetStat(LocalPlayer, "AttackRate", 1.0)
	local cooldown = rangedData.FireRate / attackSpeedMult

	local now = os.clock()
	if now - lastRangedFireTime < cooldown then return end
	lastRangedFireTime = now
	rangedAttackIdCounter += 1

	local muzzlePos = getMuzzlePosition()
	if not muzzlePos then return end
	if TargetingController then TargetingController:RefreshTarget() end

	local aimDirection
	local targetModel = nil
	local targetPosition = nil

	if TargetingController and TargetingController:HasTarget() then
		targetPosition = TargetingController:GetTargetPosition()
		targetModel = TargetingController:GetTarget()
		if targetPosition then
			aimDirection = (targetPosition - muzzlePos).Unit
			local dirToTarget = TargetingController:GetDirectionToTarget()
			if dirToTarget then
				local targetCFrame = CFrame.lookAt(rootPart.Position, rootPart.Position + dirToTarget)
				rootPart.CFrame = CFrame.new(rootPart.Position) * targetCFrame.Rotation
			end
		else
			aimDirection = rootPart.CFrame.LookVector
		end
	else
		aimDirection = rootPart.CFrame.LookVector
	end

	local spread = rangedData.Spread or 0
	if spread > 0 then
		local spreadRad = math.rad(spread)
		local randomAngle = math.random() * math.pi * 2
		local randomSpread = math.random() * spreadRad
		local right = aimDirection:Cross(Vector3.new(0, 1, 0)).Unit
		local up = right:Cross(aimDirection).Unit
		aimDirection = (aimDirection + right * math.sin(randomAngle) * math.sin(randomSpread) + up * math.cos(randomAngle) * math.sin(randomSpread)).Unit
	end

	sharedRaycastParams.FilterDescendantsInstances = { character }
	local maxRange = rangedData.Range or 60
	local rayResult = workspace:Raycast(muzzlePos, aimDirection * maxRange, sharedRaycastParams)

	local hitPosition
	local hitNormal
	local hitTarget = nil
	local didHit = false

	if rayResult then
		hitPosition = rayResult.Position
		hitNormal = rayResult.Normal
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
		hitPosition = muzzlePos + aimDirection * maxRange
	end

	if ProjectileEffects then
		if didHit then
			ProjectileEffects:PlayRangedHitEffects(muzzlePos, hitPosition, hitNormal, rangedData)
		else
			ProjectileEffects:PlayRangedMissEffects(muzzlePos, hitPosition, rangedData)
		end
	end

	if didHit and hitTarget then
		if Remotes and Remotes.RequestRangedHit then
			local attackId = LocalPlayer.UserId .. "_R_" .. rangedAttackIdCounter
			Remotes.RequestRangedHit:FireServer(hitTarget, hitPosition, attackId)
			if HitstopController and rangedData.Hitstop then
				HitstopController:ApplyHitstop(rangedData.Hitstop, { hitTarget })
			end
			if ScreenShakeController and rangedData.ScreenShake then
				ScreenShakeController:Shake(rangedData.ScreenShake, 0.1)
			end
			if DamageNumbers then
				local baseDamage = rangedData.Damage or 10
				local damage = StatLib:GetStat(LocalPlayer, "Damage", baseDamage)
				local critChance = StatLib:GetStat(LocalPlayer, "CritChance", 0)
				local isCrit = math.random() <= critChance
				if isCrit then damage = damage * 2 end
				local damageType = isCrit and "Critical" or "Normal"
				DamageNumbers:SpawnOnCharacter(hitTarget, damage, damageType)
			end
		end
	end
	CombatController.OnRangedFired:Fire(hitTarget, hitPosition, didHit)
end

function handleAttackInput()
	if ClassController and ClassController:IsClassSelected() then
		local attackType = ClassController:GetAttackType()
		if attackType == "Ranged" then
			performRangedAttack()
			return
		end
	end
	startAttack()
end

--[[
    Flamethrower Tick Logic (Refactored)
]]
local function handleFlamethrowerTick(dt)
	-- 1. Input Check
	if not InputController:IsAttackHeld() then
		isFlamethrowerActive = false
		local _, humanoid = getCharacterParts()
		if humanoid then
			local baseSpeed = StatLib:GetStat(LocalPlayer, "WalkSpeed", MovementConfig.WalkSpeed)
			humanoid.WalkSpeed = baseSpeed
		end
		local char = LocalPlayer.Character
		if char and char:FindFirstChild("HumanoidRootPart") then
			local light = char.HumanoidRootPart:FindFirstChild("FlamethrowerLight")
			if light then light:Destroy() end
		end
		if flamethrowerTrack then
			flamethrowerTrack:Stop(0.2)
			flamethrowerTrack:Destroy()
			flamethrowerTrack = nil
		end
		return
	end

	local classData = ClassController:GetClassData("BikerKing")
	local ftData = classData and classData.FlamethrowerAttack
	if not ftData then return end

	local char, humanoid, rootPart = getCharacterParts()
	if not char or not humanoid or not rootPart then return end

	if not flamethrowerTrack then
		local animId = ftData.AnimationId or "rbxassetid://507768375"
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
	if flamethrowerTrack and not flamethrowerTrack.IsPlaying then flamethrowerTrack:Play(0.1) end

	if TargetingController and TargetingController:HasTarget() then
		local dirToTarget = TargetingController:GetDirectionToTarget()
		if dirToTarget then
			local targetCFrame = CFrame.lookAt(rootPart.Position, rootPart.Position + dirToTarget)
			rootPart.CFrame = CFrame.new(rootPart.Position) * targetCFrame.Rotation
		end
	end

	local baseSpeed = StatLib:GetStat(LocalPlayer, "WalkSpeed", MovementConfig.WalkSpeed)
	humanoid.WalkSpeed = baseSpeed * (ftData.WalkSpeedMultiplier or 0.6)

	local spawnOffset = CFrame.new(2.5, 0.5, -3)
	local originCFrame = rootPart.CFrame * spawnOffset
	local forwardDir = originCFrame.LookVector
	local rightDir = originCFrame.RightVector
	local upDir = originCFrame.UpVector

	-- A) MAIN FLAME BLOCKS (VOXEL)
	if ftData.VoxelEnabled then
		for _ = 1, (ftData.VoxelCountPerFrame or 6) do
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

			local cube = VFXPool:Get("AnimeFire", getAnimeFireTemplate())
			cube.Size = Vector3.new(startSize, startSize, startSize)
			cube.Color = Color3.fromRGB(255, 255, 200)
			cube.Transparency = 0

			local rot = CFrame.Angles(math.random() * 6, math.random() * 6, math.random() * 6)
			cube.CFrame = originCFrame * rot
			cube.Parent = workspace.Terrain

			local travelDist = speed * lifetime
			local endPos = originCFrame.Position + dir * travelDist + Vector3.new(0, 4, 0)
			local startCF = cube.CFrame
			local endCF = CFrame.new(endPos) * rot * CFrame.Angles(math.random() * 3, math.random() * 3, math.random() * 3)
			local startSizeVec = cube.Size
			local endSizeVec = Vector3.new(endSize, endSize, endSize)

			VFXSystem:Play(cube, lifetime, function(inst, alpha)
				local moveAlpha = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
				inst.CFrame = startCF:Lerp(endCF, moveAlpha)
				inst.Size = startSizeVec:Lerp(endSizeVec, moveAlpha)
				inst.Transparency = moveAlpha

				if alpha < 0.1 then
					inst.Color = Color3.fromRGB(255, 255, 200)
				elseif alpha < 0.3 then
					local t = (alpha - 0.1) / 0.2
					inst.Color = Color3.fromRGB(255, 255, 200):Lerp(Color3.fromRGB(255, 180, 50), t)
				elseif alpha < 0.5 then
					local t = (alpha - 0.3) / 0.2
					inst.Color = Color3.fromRGB(255, 180, 50):Lerp(Color3.fromRGB(200, 60, 20), t)
				else
					local t = (alpha - 0.5) / 0.5
					inst.Color = Color3.fromRGB(200, 60, 20):Lerp(Color3.fromRGB(60, 60, 60), t)
				end
			end, {
				PoolName = "AnimeFire"
			})
		end
	end

	-- B) SPARK SPRAY
	if ftData.StraysEnabled then
		for _ = 1, (ftData.StrayCountPerFrame or 3) do
			local spreadAmount = ftData.StraySpread or 1.0
			local spreadX = (math.random() - 0.5) * spreadAmount
			local spreadY = (math.random() - 0.5) * spreadAmount
			local dir = (forwardDir + rightDir * spreadX + upDir * spreadY).Unit
			local speed = (ftData.StraySpeed or 110) * (0.7 + math.random() * 0.6)
			local lifetime = (ftData.StrayLifetime or 0.35)

			local spark = VFXPool:Get("FireSpark", getFireSparkTemplate())
			spark.Size = Vector3.new(0.2, 0.2, 0.2)
			spark.Color = Color3.fromRGB(255, 255, 180)
			spark.Transparency = 0
			spark.CFrame = originCFrame
			spark.Parent = workspace.Terrain

			local endPos = originCFrame.Position + dir * (speed * lifetime)

			VFXSystem:Add(spark, lifetime, {
				Position = endPos,
				Size = Vector3.new(0, 0, 0),
				Transparency = 0.5
			}, {
				EasingStyle = Enum.EasingStyle.Exponential,
				EasingDirection = Enum.EasingDirection.Out,
				PoolName = "FireSpark"
			})
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

	-- 6. Damage
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

local function onHeartbeat(dt: number)
	if isFlamethrowerActive then
		handleFlamethrowerTick(dt)
	end

	local attackType = nil
	if ClassController and ClassController:IsClassSelected() then
		attackType = ClassController:GetAttackType()
	end

	if attackType == "Ranged" then
		if InputController:IsAttackHeld() then
			local success, err = pcall(performRangedAttack)
			if not success then warn("[CombatController] Ranged attack error:", err) end
		end
	elseif attackType == "Flamethrower" then
		-- handled above
	else
		if InputController:IsAttackHeld() and not isAttacking and not isFlamethrowerActive then
			local timeSinceLastAttack = os.clock() - attackEndTime
			local attackSpeedMult = StatLib:GetStat(LocalPlayer, "AttackRate", 1.0)
			local autoInterval = ComboConfig.AutoAttackInterval / attackSpeedMult
			if timeSinceLastAttack >= autoInterval then startAttack() end
		end
		if not isAttacking and currentComboHit > 0 then
			local timeSinceLastAttack = os.clock() - lastAttackTime
			if timeSinceLastAttack > ComboConfig.ResetTime then
				currentComboHit = 0
				CombatController.OnComboReset:Fire()
			end
		end
	end
end

function CombatController:Start()
	local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if remotesFolder then
		Remotes = {
			RequestAttack = remotesFolder:FindFirstChild("RequestAttack"),
			HitConfirmed = remotesFolder:FindFirstChild("HitConfirmed"),
			RequestRangedHit = remotesFolder:FindFirstChild("RequestRangedHit"),
			RangedHitConfirmed = remotesFolder:FindFirstChild("RangedHitConfirmed"),
		}
	else
		warn("[CombatController] Remotes folder not found")
	end

	if InputController then
		table.insert(connections, InputController.OnAttackPressed:Connect(onAttackPressed))
	end
	if DashController then
		table.insert(connections, DashController.OnDashStarted:Connect(onDashStarted))
	end
	table.insert(connections, RunService.Heartbeat:Connect(onHeartbeat))
	table.insert(connections, LocalPlayer.CharacterAdded:Connect(function(character)
		isAttacking = false
		isFlamethrowerActive = false
		currentComboHit = 0
		queuedAttack = false
		lastRangedFireTime = 0
		table.clear(hitEnemiesThisSwing)
		local humanoid = character:WaitForChild("Humanoid", 5)
		if humanoid then originalWalkSpeed = humanoid.WalkSpeed end
	end))

	if Remotes and Remotes.HitConfirmed then
		table.insert(connections, Remotes.HitConfirmed.OnClientEvent:Connect(function(hitData)
			if hitData.Attacker == LocalPlayer and HitstopController and hitData.Hitstop then end
			if CombatEffects and hitData.HitPosition then
				if hitData.Attacker and hitData.Attacker.Character then
					local attackerClass = hitData.Attacker:GetAttribute("Class")
					if attackerClass == "BikerKing" then
						CombatEffects:SpawnFireHitEffect(hitData.HitPosition, hitData.AttackIndex)
					end
				end
				CombatEffects:SpawnHitEffects(hitData.HitPosition, nil, hitData.AttackIndex)
			end
		end))
	end
	print("[CombatController] Started")
end

function CombatController:Destroy()
	for _, connection in connections do connection:Disconnect() end
	table.clear(connections)
	if hitboxConnection then
		hitboxConnection:Disconnect()
		hitboxConnection = nil
	end
end

function CombatController:Init()
	InputController = require(script.Parent.InputController)
	MovementController = require(script.Parent.Parent.Features.Movement.MovementController)
	local function tryRequire(path)
		local success, result = pcall(function() return require(path) end)
		return success and result or nil
	end
	TargetingController = tryRequire(script.Parent.Parent.Features.Combat.TargetingController)
	HitstopController = tryRequire(script.Parent.Parent.VFX.HitstopController)
	ScreenShakeController = tryRequire(script.Parent.Parent.VFX.ScreenShakeController)
	CombatEffects = tryRequire(script.Parent.Parent.VFX.CombatEffects)
	DashController = tryRequire(script.Parent.DashController)
	ClassController = tryRequire(script.Parent.Parent.Features.Class.ClassController)
	ProjectileEffects = tryRequire(script.Parent.Parent.VFX.ProjectileEffects)
	DamageNumbers = tryRequire(script.Parent.Parent.VFX.DamageNumbers)
	EnemyVFXController = tryRequire(script.Parent.EnemyVFXController)
	print("[CombatController] Initialized")
end

return CombatController
