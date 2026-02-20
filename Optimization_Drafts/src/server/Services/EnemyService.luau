--[[
    EnemyService.luau
    OPTIMIZED DRAFT - 2024-05-22

    Optimizations Applied:
    1.  **Player Caching**: Implemented `playerCache` to store references to active Player RootParts.
        - Removes O(P) calls to `FindFirstChild` inside the hot AI loop.
        - Eliminates iteration over players who don't have characters.
    2.  **Optimized Nearest Search**: `getNearestPlayer` now iterates the cache and performs cheap distance checks before expensive Health checks.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local _PathfindingService = game:GetService("PathfindingService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local EnemyConfig = require(Shared:WaitForChild("Config"):WaitForChild("EnemyConfig"))
local CombatConfig = require(Shared:WaitForChild("Config"):WaitForChild("CombatConfig"))
local MovementConfig = require(Shared:WaitForChild("Config"):WaitForChild("MovementConfig"))
local EnemyLib = require(Shared:WaitForChild("Lib"):WaitForChild("EnemyLib"))

local EnemyService = {
	Name = "EnemyService",
}

local AIState = {
	Idle = "Idle",
	Chase = "Chase",
	Attack = "Attack",
	LeapAttack = "LeapAttack",
	Hitstun = "Hitstun",
	Dead = "Dead",
}

local activeEnemies: { [Model]: EnemyData } = {}
local playerIFrames: { [Player]: number } = {}
local playerLastDash: { [Player]: number } = {}

-- OPTIMIZATION: Player RootPart Cache
local playerCache: { [Player]: BasePart } = {}

type EnemyData = {
	Model: Model,
	RootPart: BasePart,
	LinearVelocity: LinearVelocity?,
	AlignOrientation: AlignOrientation?,
	Animator: Animator?,
	WalkTrack: AnimationTrack?,
	EnemyType: string,
	Config: any,
	State: string,
	Target: Player?,
	LastAttackTime: number,
	LastPathUpdate: number,
	Path: Path?,
	PathWaypoints: { PathWaypoint }?,
	CurrentWaypointIndex: number,
	HitstunEndTime: number,
	AggroTime: number,
	IsMoving: boolean,
	LastMoveTarget: Vector3?,
	LastPos: Vector3?,
	LastPosTime: number?,
	AttackTriggered: boolean,
	CurrentAttack: any?,
}

local aiUpdateAccumulator = 0

--[[
    Get the nearest player to an enemy within aggro range
    OPTIMIZED: Uses cache + deferred health check
]]
local function getNearestPlayer(enemyPosition: Vector3, aggroRange: number): Player?
	local nearestPlayer: Player? = nil
	local nearestDistance = aggroRange

    -- Iterate cached roots (fast)
	for player, rootPart in playerCache do
        if not rootPart.Parent then
            playerCache[player] = nil -- Lazy cleanup
            continue
        end

		local distance = (rootPart.Position - enemyPosition).Magnitude
		if distance < nearestDistance then
            -- Only check health if physically close enough (optimization)
            local character = player.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")

            if humanoid and humanoid.Health > 0 then
			    nearestDistance = distance
			    nearestPlayer = player
            end
		end
	end

	return nearestPlayer
end

--[[
    Get target position from a player
    OPTIMIZED: Uses cache
]]
local function getTargetPosition(player: Player): Vector3?
    local cachedRoot = playerCache[player]
    if cachedRoot and cachedRoot.Parent then
        return cachedRoot.Position
    end

    -- Fallback
	local character = player.Character
	if not character then return nil end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return nil end
	return rootPart.Position
end

--[[
    Check if target is still valid (alive and in range)
]]
local function isTargetValid(enemyData: EnemyData): boolean
	if not enemyData.Target then return false end

    -- OPTIMIZATION: Check cache first
    local rootPart = playerCache[enemyData.Target]
    if not rootPart or not rootPart.Parent then return false end

	local character = enemyData.Target.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return false end

	local distance = (rootPart.Position - enemyData.RootPart.Position).Magnitude
	if distance > EnemyConfig.Aggro.ChaseRange then return false end

	return true
end

--[[
    Move enemy toward target using direct movement
]]
local function moveTowardTarget(enemyData: EnemyData)
	if not enemyData.Target then return end
	local targetPos = getTargetPosition(enemyData.Target)
	if not targetPos then return end

	local currentPos = enemyData.RootPart.Position
	local fullDiff = targetPos - currentPos
	local horizontalDist = Vector3.new(fullDiff.X, 0, fullDiff.Z).Magnitude
	local verticalDist = math.abs(fullDiff.Y)

	if verticalDist > horizontalDist * 1.5 and verticalDist > 4 then
		if enemyData.IsMoving then
			if enemyData.LinearVelocity then enemyData.LinearVelocity.PlaneVelocity = Vector2.zero end
			enemyData.IsMoving = false
			enemyData.LastMoveTarget = nil
		end
		return
	end

	local distanceToTarget = horizontalDist
	local stopDistance = enemyData.Config.StopDistanceFromTarget or 2.5
	local startChaseDistance = stopDistance + 1.5

	if distanceToTarget <= stopDistance then
		if enemyData.IsMoving then
			if enemyData.LinearVelocity then enemyData.LinearVelocity.PlaneVelocity = Vector2.zero end
			enemyData.IsMoving = false
			enemyData.LastMoveTarget = nil
		end
		return
	end

	if not enemyData.IsMoving and distanceToTarget < startChaseDistance then return end

	local needsNewMove = false
	if not enemyData.LastMoveTarget then
		needsNewMove = true
	else
		local targetMovedDistance = (targetPos - enemyData.LastMoveTarget).Magnitude
		if targetMovedDistance > 2 then needsNewMove = true end
	end

	if enemyData.IsMoving then
		if not enemyData.LastPos then
			enemyData.LastPos = currentPos
			enemyData.LastPosTime = tick()
		elseif tick() - enemyData.LastPosTime > 1.0 then
			local distMoved = (currentPos - enemyData.LastPos).Magnitude
			if distMoved < 1.0 then
				enemyData.RootPart.AssemblyLinearVelocity = Vector3.new(0, 30, 0)
				needsNewMove = true
			end
			enemyData.LastPos = currentPos
			enemyData.LastPosTime = tick()
		end
	end

	if needsNewMove and enemyData.LinearVelocity then
		local direction = (targetPos - currentPos)
		direction = Vector3.new(direction.X, 0, direction.Z)
		if direction.Magnitude > 0.1 then
			local speed: number = (enemyData.Model:GetAttribute("WalkSpeed") :: number?) or 14
			local dir2D = direction.Unit
			enemyData.LinearVelocity.PlaneVelocity = Vector2.new(dir2D.X, dir2D.Z) * speed
		end
		enemyData.IsMoving = true
		enemyData.LastMoveTarget = targetPos
	end
end

--[[
    Face the target
]]
local function faceTarget(enemyData: EnemyData)
	if not enemyData.Target then return end
	local targetPos = getTargetPosition(enemyData.Target)
	if not targetPos then return end

	local fullDirection = targetPos - enemyData.RootPart.Position
	local horizontalDir = Vector3.new(fullDirection.X, 0, fullDirection.Z)
	local horizontalDist = horizontalDir.Magnitude
	local verticalDist = math.abs(fullDirection.Y)

	if horizontalDist < 3 or verticalDist > horizontalDist * 1.5 then return end

	local direction = horizontalDir
	local targetCFrame = CFrame.lookAt(enemyData.RootPart.Position, enemyData.RootPart.Position + direction)
	if enemyData.AlignOrientation then
		enemyData.AlignOrientation.CFrame = targetCFrame
	else
		local align = enemyData.RootPart:FindFirstChild("EnemyAlignOrientation")
		if align then
			(align :: AlignOrientation).CFrame = targetCFrame
			enemyData.AlignOrientation = align :: AlignOrientation
		else
			enemyData.RootPart.CFrame = enemyData.RootPart.CFrame:Lerp(targetCFrame, 0.2)
		end
	end
end

--[[
    Pick a random attack
]]
local function pickWeightedAttack(attacks: { any }, distanceToTarget: number?): any
	local eligible = {}
	for _, atk in attacks do
		local inRange = true
		if distanceToTarget and atk.MinRange and distanceToTarget < atk.MinRange then inRange = false end
		if distanceToTarget and atk.MaxRange and distanceToTarget > atk.MaxRange then inRange = false end
		if inRange then table.insert(eligible, atk) end
	end

	if #eligible == 0 then eligible = attacks end
	local totalWeight = 0
	for _, atk in eligible do totalWeight += (atk.Weight or 1) end
	local roll = math.random() * totalWeight
	local cumulative = 0
	for _, atk in eligible do
		cumulative += (atk.Weight or 1)
		if roll <= cumulative then return atk end
	end
	return eligible[1]
end

--[[
    Apply speed curve
]]
local function applySpeedCurve(track: AnimationTrack, duration: number, curve: { { number } })
	task.spawn(function()
		local startTime = tick()
		while tick() - startTime < duration do
			local elapsed = tick() - startTime
			local t = math.clamp(elapsed / duration, 0, 1)
			local speed = curve[1][2]
			for i = 1, #curve - 1 do
				local k0 = curve[i]
				local k1 = curve[i + 1]
				if t >= k0[1] and t <= k1[1] then
					local alpha = (t - k0[1]) / (k1[1] - k0[1])
					speed = k0[2] + (k1[2] - k0[2]) * alpha
					break
				elseif t > k1[1] then
					speed = k1[2]
				end
			end
			track:AdjustSpeed(speed)
			task.wait()
		end
	end)
end

--[[
    Perform Leap Attack
]]
local function performLeapAttack(enemyData: EnemyData)
	if not enemyData.Target then return end
	local target = enemyData.Target
	local attackData = enemyData.CurrentAttack
	if not attackData then return end

	local windupDuration = attackData.WindupDuration or 1.2
	local launchDuration = attackData.LaunchDuration or 0.5
	local flightDuration = attackData.FlightDuration or 0.6
	local flightHeight = attackData.FlightHeight or 40
	local landDuration = attackData.LandDuration or 0.8
	local attackDamage = attackData.Damage or 25
	local hitRadius = attackData.HitRadius or 20
	local vfxType = attackData.VFXType or "LeapSlam"

	local rootPart = enemyData.RootPart
	if not rootPart or not rootPart.Parent then return end

	if enemyData.LinearVelocity then enemyData.LinearVelocity.PlaneVelocity = Vector2.zero end
	faceTarget(enemyData)

	local windupTrack = nil
	if attackData.WindupAnimId and enemyData.Animator then
		pcall(function()
			local anim = Instance.new("Animation")
			anim.AnimationId = attackData.WindupAnimId
			windupTrack = enemyData.Animator:LoadAnimation(anim)
			windupTrack.Priority = Enum.AnimationPriority.Action4
			windupTrack:Play()
			windupTrack:AdjustSpeed(attackData.WindupAnimSpeed or 1.0)
		end)
	end

	local enemyAttackRemote = Remotes:GetEvent("EnemyAttack")
	if enemyAttackRemote then
		enemyAttackRemote:FireAllClients({
			Enemy = enemyData.Model,
			Target = target,
			HitPosition = rootPart.Position,
			Damage = attackDamage,
			AttackType = "LeapStart",
		})
	end

	task.wait(windupDuration)

	if not rootPart or not rootPart.Parent or enemyData.State == AIState.Dead then
		if windupTrack then windupTrack:Stop() end
		return
	end

	if windupTrack then windupTrack:Stop(0.1) end
	local midairTrack = nil
	if attackData.MidairAnimId and enemyData.Animator then
		pcall(function()
			local anim = Instance.new("Animation")
			anim.AnimationId = attackData.MidairAnimId
			midairTrack = enemyData.Animator:LoadAnimation(anim)
			midairTrack.Priority = Enum.AnimationPriority.Action4
			midairTrack.Looped = true
			midairTrack:Play()
		end)
	end

	local startPos = rootPart.Position
	local baseY = startPos.Y
	local wasAnchored = rootPart.Anchored
	rootPart.Anchored = true
	if enemyData.LinearVelocity then enemyData.LinearVelocity.PlaneVelocity = Vector2.zero end

	local launchStart = tick()
	while true do
		local elapsed = tick() - launchStart
		local t = math.clamp(elapsed / launchDuration, 0, 1)
		if t >= 1 then break end
		local easedT = 1 - (1 - t) * (1 - t)
		local currentY = baseY + flightHeight * easedT
		rootPart.CFrame = CFrame.lookAt(
			Vector3.new(startPos.X, currentY, startPos.Z),
			Vector3.new(startPos.X, currentY, startPos.Z) + rootPart.CFrame.LookVector
		)
		task.wait()
	end

	local peakY = baseY + flightHeight
	rootPart.CFrame = CFrame.lookAt(
		Vector3.new(startPos.X, peakY, startPos.Z),
		Vector3.new(startPos.X, peakY, startPos.Z) + rootPart.CFrame.LookVector
	)

	if not rootPart or not rootPart.Parent or enemyData.State == AIState.Dead then
		if midairTrack then midairTrack:Stop() end
		rootPart.Anchored = wasAnchored
		return
	end

	local targetPos = getTargetPosition(target)
	if not targetPos then
		if midairTrack then midairTrack:Stop() end
		rootPart.Anchored = wasAnchored
		enemyData.State = AIState.Chase
		return
	end

	local flightStartPos = rootPart.Position
	local landingPos = targetPos
	local flightStart = tick()
	while true do
		local elapsed = tick() - flightStart
		local t = math.clamp(elapsed / flightDuration, 0, 1)
		if t >= 1 then break end
		local easedT = t * t
		local currentX = flightStartPos.X + (landingPos.X - flightStartPos.X) * t
		local currentZ = flightStartPos.Z + (landingPos.Z - flightStartPos.Z) * t
		local currentY = flightStartPos.Y + (landingPos.Y - flightStartPos.Y) * easedT
		local currentPos = Vector3.new(currentX, currentY, currentZ)
		local lookTarget = Vector3.new(landingPos.X, currentY, landingPos.Z)
		if (lookTarget - currentPos).Magnitude > 1 then
			rootPart.CFrame = CFrame.lookAt(currentPos, lookTarget)
		else
			rootPart.CFrame = CFrame.new(currentPos) * CFrame.Angles(0, select(2, rootPart.CFrame:ToEulerAnglesYXZ()), 0)
		end
		task.wait()
	end

	rootPart.Anchored = wasAnchored
	if midairTrack then midairTrack:Stop(0.1) end

	if attackData.LandAnimId and enemyData.Animator then
		pcall(function()
			local anim = Instance.new("Animation")
			anim.AnimationId = attackData.LandAnimId
			local landTrack = enemyData.Animator:LoadAnimation(anim)
			landTrack.Priority = Enum.AnimationPriority.Action4
			landTrack:Play()
		end)
	end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = CollectionService:GetTagged(CombatConfig.Targeting.TargetTag)
	local rayOrigin = Vector3.new(landingPos.X, rootPart.Position.Y + 5, landingPos.Z)
	local rayResult = workspace:Raycast(rayOrigin, Vector3.new(0, -60, 0), rayParams)
	local impactPos = if rayResult then rayResult.Position else landingPos

	rootPart.CFrame = CFrame.new(impactPos.X, impactPos.Y + 3, impactPos.Z) * CFrame.Angles(0, select(2, rootPart.CFrame:ToEulerAnglesYXZ()), 0)

	if enemyAttackRemote then
		enemyAttackRemote:FireAllClients({
			Enemy = enemyData.Model,
			Target = target,
			HitPosition = impactPos,
			Damage = attackDamage,
			AttackType = vfxType,
			IsSlam = true,
		})
	end

	for _, player in Players:GetPlayers() do
		local character = player.Character
		if not character then continue end
		local targetRoot = character:FindFirstChild("HumanoidRootPart")
		if not targetRoot then continue end
		local dist = (targetRoot.Position - impactPos).Magnitude
		if dist > hitRadius then continue end
		local targetHumanoid = character:FindFirstChildOfClass("Humanoid")
		if not targetHumanoid or targetHumanoid.Health <= 0 then continue end
		local iframeExpiry = playerIFrames[player]
		if iframeExpiry and tick() < iframeExpiry then
			local damageBlockedRemote = Remotes:GetEvent("DamageBlocked")
			if damageBlockedRemote then
				damageBlockedRemote:FireClient(player, { Enemy = enemyData.Model, Position = targetRoot.Position, DamageBlocked = attackDamage })
			end
			continue
		end
		local damage = attackDamage
		local resistance = character:GetAttribute("DamageResistance") or 0
		if resistance > 0 then damage = damage * (1 - math.clamp(resistance, 0, 1)) end
		local currentShield = character:GetAttribute("Shield") or 0
		if currentShield > 0 then
			if currentShield >= damage then
				character:SetAttribute("Shield", currentShield - damage)
				damage = 0
			else
				damage = damage - currentShield
				character:SetAttribute("Shield", 0)
			end
		end
		if damage > 0 then targetHumanoid:TakeDamage(damage) end
		local knockbackDir = (targetRoot.Position - impactPos)
		knockbackDir = Vector3.new(knockbackDir.X, 0.5, knockbackDir.Z).Unit
		targetRoot.AssemblyLinearVelocity = targetRoot.AssemblyLinearVelocity + knockbackDir * 35
	end

	task.delay(landDuration, function()
		if enemyData.State == AIState.LeapAttack then
			enemyData.State = AIState.Chase
			enemyData.CurrentAttack = nil
			if enemyData.WalkTrack and not enemyData.WalkTrack.IsPlaying then
				enemyData.WalkTrack:Play(0.2)
			end
		end
	end)
end

--[[
    Perform Attack
]]
local function performAttack(enemyData: EnemyData)
	if not enemyData.Target then return end
	local target = enemyData.Target
	local config = enemyData.Config
	local attackData = enemyData.CurrentAttack

	local windup = if attackData then attackData.Windup else (config.AttackWindup or 0.3)
	local attackDamage = if attackData then attackData.Damage else (config.Damage or 5)
	local forwardDist = if attackData then attackData.ForwardDist else 4
	local hitRadius = if attackData then attackData.HitRadius else 15
	local vfxType = if attackData then attackData.VFXType else nil

	task.delay(windup, function()
		if not enemyData.RootPart or not enemyData.RootPart.Parent or enemyData.State == AIState.Dead then return end

		local impactPos = enemyData.RootPart.Position + (enemyData.RootPart.CFrame.LookVector * forwardDist)
		local rayParams = RaycastParams.new()
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		rayParams.FilterDescendantsInstances = CollectionService:GetTagged(CombatConfig.Targeting.TargetTag)
		local rayOrigin = Vector3.new(impactPos.X, enemyData.RootPart.Position.Y + 5, impactPos.Z)
		local rayResult = workspace:Raycast(rayOrigin, Vector3.new(0, -20, 0), rayParams)
		if rayResult then impactPos = rayResult.Position
		else impactPos = Vector3.new(impactPos.X, enemyData.RootPart.Position.Y - 3, impactPos.Z) end

		local enemyAttackRemote = Remotes:GetEvent("EnemyAttack")
		if enemyAttackRemote then
			enemyAttackRemote:FireAllClients({
				Enemy = enemyData.Model,
				Target = target,
				HitPosition = impactPos,
				Damage = attackDamage,
				AttackType = vfxType,
				IsSlam = (vfxType == "Slam"),
			})
		end

		local character = target.Character
		if not character then return end
		local targetRoot = character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("Root")
		if not targetRoot then return end

		local distToImpact = (targetRoot.Position - impactPos).Magnitude
		local distToEnemy = (targetRoot.Position - enemyData.RootPart.Position).Magnitude
		if distToImpact > hitRadius and distToEnemy > (config.AttackRange or 5) + 2 then return end

		local targetHumanoid = character:FindFirstChildOfClass("Humanoid")
		if not targetHumanoid or targetHumanoid.Health <= 0 then return end

		local iframeExpiry = playerIFrames[target]
		if iframeExpiry and tick() < iframeExpiry then
			local damageBlockedRemote = Remotes:GetEvent("DamageBlocked")
			if damageBlockedRemote then
				damageBlockedRemote:FireClient(target, { Enemy = enemyData.Model, Position = targetRoot.Position, DamageBlocked = attackDamage })
			end
			return
		end

		local damage = attackDamage
		local resistance = character:GetAttribute("DamageResistance") or 0
		if resistance > 0 then damage = damage * (1 - math.clamp(resistance, 0, 1)) end
		local currentShield = character:GetAttribute("Shield") or 0
		if currentShield > 0 then
			if currentShield >= damage then
				character:SetAttribute("Shield", currentShield - damage)
				damage = 0
			else
				damage = damage - currentShield
				character:SetAttribute("Shield", 0)
			end
		end

		if damage > 0 then targetHumanoid:TakeDamage(damage) end
		local knockbackDir = (targetRoot.Position - enemyData.RootPart.Position)
		knockbackDir = Vector3.new(knockbackDir.X, 0.3, knockbackDir.Z).Unit
		targetRoot.AssemblyLinearVelocity = targetRoot.AssemblyLinearVelocity + knockbackDir * 20
	end)
end

--[[
    Update AI
]]
local function updateEnemyAI(enemyData: EnemyData, deltaTime: number)
	local config = enemyData.Config
	local now = tick()
	local oldState = enemyData.State

	if not EnemyLib:IsAlive(enemyData.Model) then
		if enemyData.State ~= AIState.Dead then
			enemyData.State = AIState.Dead
			local stateRemote = Remotes:GetEvent("EnemyStateChanged")
			if stateRemote then stateRemote:FireAllClients(enemyData.Model, AIState.Dead) end
		end
		return
	end

	if enemyData.State == AIState.Hitstun then
		if now >= enemyData.HitstunEndTime then enemyData.State = AIState.Idle
		else return end
	end

	if enemyData.State == AIState.Idle then
		local nearestPlayer = getNearestPlayer(enemyData.RootPart.Position, config.AggroRange or EnemyConfig.Aggro.DetectionRange)
		if nearestPlayer then
			enemyData.Target = nearestPlayer
			enemyData.State = AIState.Chase
			enemyData.AggroTime = now
			enemyData.LastPathUpdate = 0
			if enemyData.WalkTrack and not enemyData.WalkTrack.IsPlaying then enemyData.WalkTrack:Play() end
		end
	elseif enemyData.State == AIState.Chase then
		if not isTargetValid(enemyData) then
			enemyData.Target = nil
			enemyData.State = AIState.Idle
			enemyData.IsMoving = false
			enemyData.LastMoveTarget = nil
			if enemyData.LinearVelocity then enemyData.LinearVelocity.PlaneVelocity = Vector2.zero end
			if enemyData.WalkTrack and enemyData.WalkTrack.IsPlaying then enemyData.WalkTrack:Stop(0.2) end
			return
		end

		local targetPos = getTargetPosition(enemyData.Target)
		if targetPos then
			local distanceToTarget = (targetPos - enemyData.RootPart.Position).Magnitude
			local distance = distanceToTarget
			local attackRange = config.AttackRange or 4

			if distance <= attackRange then
				if now - enemyData.LastAttackTime >= (config.AttackCooldown or 1.5) then
					enemyData.State = AIState.Attack
					enemyData.LastAttackTime = now
					enemyData.AttackTriggered = false
					enemyData.IsMoving = false
					enemyData.LastMoveTarget = nil
					if enemyData.LinearVelocity then enemyData.LinearVelocity.PlaneVelocity = Vector2.zero end
					if enemyData.WalkTrack and enemyData.WalkTrack.IsPlaying then enemyData.WalkTrack:Stop(0.15) end
				end
			else
				local canLeap = false
				if config.Attacks and now - enemyData.LastAttackTime >= (config.AttackCooldown or 1.5) then
					for _, atk in config.Attacks do
						if atk.Type == "Leap" and atk.MinRange and atk.MaxRange then
							if distance >= atk.MinRange and distance <= atk.MaxRange then
								enemyData.State = AIState.Attack
								enemyData.LastAttackTime = now
								enemyData.AttackTriggered = false
								enemyData.IsMoving = false
								enemyData.LastMoveTarget = nil
								if enemyData.LinearVelocity then enemyData.LinearVelocity.PlaneVelocity = Vector2.zero end
								if enemyData.WalkTrack and enemyData.WalkTrack.IsPlaying then enemyData.WalkTrack:Stop(0.15) end
								enemyData.CurrentAttack = atk
								canLeap = true
								break
							end
						end
					end
				end

				if not canLeap then
					moveTowardTarget(enemyData)
					faceTarget(enemyData)
				end
			end
		end
	elseif enemyData.State == AIState.Attack then
		faceTarget(enemyData)
		if not enemyData.AttackTriggered then
			enemyData.AttackTriggered = true
			local attackData = enemyData.CurrentAttack
			if not attackData then
				if config.Attacks then
					local attackTargetPos = getTargetPosition(enemyData.Target)
					local atkDist = if attackTargetPos then (attackTargetPos - enemyData.RootPart.Position).Magnitude else nil
					attackData = pickWeightedAttack(config.Attacks, atkDist)
					enemyData.CurrentAttack = attackData
				end
			end

			local animId = if attackData then attackData.AnimationId else config.SlamAnimationId
			local attackDuration = if attackData then attackData.Duration else (config.AttackDuration or 0.6)

			if animId and enemyData.Animator then
				local ok, animErr = pcall(function()
					local animation = Instance.new("Animation")
					animation.AnimationId = animId
					local track = enemyData.Animator:LoadAnimation(animation)
					track.Priority = Enum.AnimationPriority.Action
					track:Play()
					if attackData and attackData.SpeedCurve then applySpeedCurve(track, attackDuration, attackData.SpeedCurve) end
				end)
				if not ok then warn("[EnemyService] Animation error for", enemyData.EnemyType, ":", animErr) end
			end

			if attackData and attackData.Type == "Leap" then
				enemyData.State = AIState.LeapAttack
				task.spawn(function() performLeapAttack(enemyData) end)
			else
				performAttack(enemyData)
				task.delay(attackDuration, function()
					if enemyData.State == AIState.Attack then
						enemyData.State = AIState.Chase
						enemyData.CurrentAttack = nil
						if enemyData.WalkTrack and not enemyData.WalkTrack.IsPlaying then enemyData.WalkTrack:Play(0.2) end
					end
				end)
			end
		end
	end

	if enemyData.State ~= oldState then
		local stateRemote = Remotes:GetEvent("EnemyStateChanged")
		if stateRemote then stateRemote:FireAllClients(enemyData.Model, enemyData.State) end
	end
end

function EnemyService:ApplyHitstun(enemyModel: Model, duration: number?)
	local enemyData = activeEnemies[enemyModel]
	if not enemyData then return end
	if enemyData.State == AIState.Dead then return end

	local hitstunDuration = duration or enemyData.Config.HitstunDuration or 0.3
	local resistance = enemyData.Config.KnockbackResistance or 0
	hitstunDuration = hitstunDuration * (1 - resistance)

	if hitstunDuration > 0 then
		local oldState = enemyData.State
		enemyData.State = AIState.Hitstun
		enemyData.HitstunEndTime = tick() + hitstunDuration
		enemyData.IsMoving = false
		enemyData.LastMoveTarget = nil
		if enemyData.WalkTrack and enemyData.WalkTrack.IsPlaying then enemyData.WalkTrack:Stop(0.1) end
		if enemyData.LinearVelocity then enemyData.LinearVelocity.VectorVelocity = Vector3.zero end

		local knockbackDuration = 0.15
		task.delay(knockbackDuration, function()
			if not enemyData.RootPart or not enemyData.RootPart.Parent then return end
			if enemyData.State ~= AIState.Hitstun then return end
			local currentVel = enemyData.RootPart.AssemblyLinearVelocity
			enemyData.RootPart.AssemblyLinearVelocity = Vector3.new(0, math.min(currentVel.Y, 0), 0)
		end)

		if oldState ~= AIState.Hitstun then
			local stateRemote = Remotes:GetEvent("EnemyStateChanged")
			if stateRemote then stateRemote:FireAllClients(enemyData.Model, AIState.Hitstun) end
		end
	end
end

function EnemyService:RegisterEnemy(enemyModel: Model, enemyType: string?)
	local rootPart = enemyModel:FindFirstChild("HumanoidRootPart")
		or enemyModel:FindFirstChild("Root")
		or enemyModel:FindFirstChild("Torso")
		or enemyModel.PrimaryPart
	if not rootPart then return end

	local typeKey = enemyType or enemyModel.Name
	local config = EnemyConfig.Types[typeKey]
	if not config then
		config = EnemyConfig.Types.Minion
		typeKey = "Minion"
	end

	local healthMultiplier = 1.0
	local speedMultiplier = 1.0
	local damageMultiplier = 1.0

	local DirectorService = _G.DirectorService
	if DirectorService and DirectorService:IsRunning() then
		local multipliers = DirectorService:GetStatMultipliers()
		healthMultiplier = multipliers.Health
		speedMultiplier = multipliers.Speed
		damageMultiplier = multipliers.Damage
	end

	local scaledHealth = math.floor(config.Health * healthMultiplier)
	local scaledSpeed = config.WalkSpeed * speedMultiplier
	local scaledDamage = config.Damage * damageMultiplier

	EnemyLib:SetupAttributes(enemyModel, scaledHealth, scaledHealth, scaledSpeed)

	local scaledConfig = {}
	for k, v in config do scaledConfig[k] = v end
	scaledConfig.Damage = scaledDamage

	enemyModel:SetAttribute("HealthMultiplier", healthMultiplier)
	enemyModel:SetAttribute("DamageMultiplier", damageMultiplier)
	enemyModel:SetAttribute("SpeedMultiplier", speedMultiplier)
	CollectionService:AddTag(enemyModel, CombatConfig.Targeting.TargetTag)

	if rootPart:IsA("BasePart") then rootPart:SetNetworkOwner(nil) end

	for _, part in enemyModel:GetDescendants() do
		if part:IsA("BasePart") then
			part.CollisionGroup = "Enemies"
			part.CanCollide = false
			if part ~= rootPart then part.Massless = true end
		end
	end

	local modelCF, modelSize = enemyModel:GetBoundingBox()
	local feetY = modelCF.Position.Y - modelSize.Y / 2
	local distToFeet = rootPart.Position.Y - feetY
	local boxHeight = distToFeet + rootPart.Size.Y * 0.5

	local collisionBox = Instance.new("Part")
	collisionBox.Name = "GroundCollision"
	collisionBox.Transparency = 1
	collisionBox.CanCollide = true
	collisionBox.CanQuery = false
	collisionBox.CanTouch = false
	collisionBox.Massless = true
	collisionBox.Size = Vector3.new(rootPart.Size.X, boxHeight, rootPart.Size.Z)
	collisionBox.CollisionGroup = "Enemies"
	local yOffset = -distToFeet + boxHeight / 2
	collisionBox.CFrame = rootPart.CFrame * CFrame.new(0, yOffset, 0)
	collisionBox.Parent = enemyModel

	local collisionWeld = Instance.new("WeldConstraint")
	collisionWeld.Part0 = rootPart
	collisionWeld.Part1 = collisionBox
	collisionWeld.Parent = collisionBox

	local attachment = rootPart:FindFirstChild("RootAttachment")
	if not attachment then
		attachment = Instance.new("Attachment")
		attachment.Name = "RootAttachment"
		attachment.Parent = rootPart
	end

	local linearVelocity = Instance.new("LinearVelocity")
	linearVelocity.Name = "EnemyMoveVelocity"
	linearVelocity.Attachment0 = attachment
	linearVelocity.MaxForce = 50000
	linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	linearVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	linearVelocity.PrimaryTangentAxis = Vector3.new(1, 0, 0)
	linearVelocity.SecondaryTangentAxis = Vector3.new(0, 0, 1)
	linearVelocity.PlaneVelocity = Vector2.zero
	linearVelocity.Parent = rootPart

	local alignAttachment = Instance.new("Attachment")
	alignAttachment.Name = "AlignAttachment"
	alignAttachment.Parent = rootPart
	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "EnemyAlignOrientation"
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0 = alignAttachment
	alignOrientation.CFrame = rootPart.CFrame
	alignOrientation.MaxTorque = math.huge
	alignOrientation.MaxAngularVelocity = math.huge
	alignOrientation.Responsiveness = 200
	alignOrientation.RigidityEnabled = true
	alignOrientation.Parent = rootPart

	local animController = enemyModel:FindFirstChildOfClass("AnimationController")
	local animator: Animator? = nil
	if not animController then
		animController = Instance.new("AnimationController")
		animController.Parent = enemyModel
	end
	animator = animController:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = animController
	end

	local existingHumanoid = enemyModel:FindFirstChildOfClass("Humanoid")
	if existingHumanoid then existingHumanoid:Destroy() end

	local walkTrack: AnimationTrack? = nil
	if scaledConfig.WalkAnimationId and animator then
		local ok, result = pcall(function()
			local walkAnim = Instance.new("Animation")
			walkAnim.AnimationId = scaledConfig.WalkAnimationId
			local track = animator:LoadAnimation(walkAnim)
			track.Looped = true
			track.Priority = Enum.AnimationPriority.Movement
			track:AdjustSpeed(scaledConfig.WalkAnimationSpeed or 1)
			return track
		end)
		if ok then walkTrack = result
		else warn("[EnemyService] Walk animation error for", typeKey, ":", result) end
	end

	local enemyData: EnemyData = {
		Model = enemyModel,
		RootPart = rootPart,
		LinearVelocity = linearVelocity,
		AlignOrientation = alignOrientation,
		Animator = animator,
		WalkTrack = walkTrack,
		EnemyType = typeKey,
		Config = scaledConfig,
		State = AIState.Idle,
		Target = nil,
		LastAttackTime = 0,
		LastPathUpdate = 0,
		Path = nil,
		PathWaypoints = nil,
		CurrentWaypointIndex = 1,
		HitstunEndTime = 0,
		AggroTime = 0,
		IsMoving = false,
		LastMoveTarget = nil,
		AttackTriggered = false,
	}

	activeEnemies[enemyModel] = enemyData

	enemyModel:GetAttributeChangedSignal("IsDead"):Connect(function()
		if not enemyModel:GetAttribute("IsDead") then return end
		enemyData.State = AIState.Dead
		if enemyData.LinearVelocity then enemyData.LinearVelocity.PlaneVelocity = Vector2.zero end
		if enemyData.WalkTrack and enemyData.WalkTrack.IsPlaying then enemyData.WalkTrack:Stop(0) end

		local enemyDiedRemote = Remotes:GetEvent("EnemyDied")
		if enemyDiedRemote then
			enemyDiedRemote:FireAllClients({
				Target = enemyModel,
				Killer = enemyData.Target,
				Position = rootPart.Position,
			})
		end

		for _, part in enemyModel:GetDescendants() do
			if part:IsA("BasePart") then
				part.CanQuery = false
				part.CanTouch = false
				part.CollisionGroup = "Debris"
			end
		end

		task.delay(EnemyConfig.Death.RagdollDuration, function()
			activeEnemies[enemyModel] = nil
			for _, part in enemyModel:GetDescendants() do
				if part:IsA("BasePart") then part.CanCollide = false end
			end
			task.delay(EnemyConfig.Death.FadeOutDuration, function()
				if enemyModel and enemyModel.Parent then enemyModel:Destroy() end
			end)
		end)
	end)

	local lastHealth = scaledHealth
	enemyModel:GetAttributeChangedSignal("Health"):Connect(function()
		local newHealth: number = (enemyModel:GetAttribute("Health") :: number?) or 0
		if newHealth < lastHealth then EnemyService:ApplyHitstun(enemyModel) end
		lastHealth = newHealth
	end)

	print("[EnemyService] Registered enemy:", enemyModel.Name, "Type:", typeKey, "(Humanoid-free)")
	return enemyData
end

function EnemyService:SpawnEnemy(enemyType: string, position: Vector3, parent: Instance?): Model?
	local config = EnemyConfig.Types[enemyType]
	if not config then return nil end

	local enemyCount = 0
	for _ in activeEnemies do enemyCount += 1 end
	if enemyCount >= EnemyConfig.AI.MaxActiveEnemies then
		warn("[EnemyService] Max enemy cap reached")
		return nil
	end

	local enemyModel: Model? = nil
	local assetsFolder = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Assets")
	local enemiesFolder = assetsFolder:FindFirstChild("Enemies")

	if enemiesFolder then
		local asset = enemiesFolder:FindFirstChild(enemyType)
		if asset then enemyModel = asset:Clone() end
	end

	if not enemyModel then
		enemyModel = Instance.new("Model")
		enemyModel.Name = enemyType
		local torso = Instance.new("Part")
		torso.Name = "HumanoidRootPart"
		torso.Size = Vector3.new(2, 2, 1)
		torso.Position = position
		torso.Anchored = false
		torso.CanCollide = true
		if enemyType == "Brute" then
			torso.Color = Color3.fromRGB(200, 50, 50)
			torso.Size = Vector3.new(3, 3, 1.5)
		elseif enemyType == "Shooter" then
			torso.Color = Color3.fromRGB(200, 200, 50)
		else
			torso.Color = Color3.fromRGB(150, 150, 150)
		end
		torso.Parent = enemyModel

		local head = Instance.new("Part")
		head.Name = "Head"
		head.Size = Vector3.new(1, 1, 1)
		head.Position = position + Vector3.new(0, 2, 0)
		head.Color = torso.Color
		head.Anchored = false
		head.CanCollide = false
		head.Parent = enemyModel

		local weld = Instance.new("Weld")
		weld.Part0 = torso
		weld.Part1 = head
		weld.C0 = CFrame.new(0, 1.5, 0)
		weld.Parent = torso
		enemyModel.PrimaryPart = torso
	end

	enemyModel.Parent = parent or workspace
	if enemyModel and enemyModel.PrimaryPart then
		local cframe, size = enemyModel:GetBoundingBox()
		local heightOffset = size.Y / 2 + 1
		enemyModel:PivotTo(CFrame.new(position + Vector3.new(0, heightOffset, 0)))
	end

	if enemyModel then self:RegisterEnemy(enemyModel, enemyType) end
	return enemyModel
end

function EnemyService:GetEnemyCount(): number
	local count = 0
	for _ in activeEnemies do count += 1 end
	return count
end

function EnemyService:GetActiveEnemies(): { [Model]: EnemyData }
	return activeEnemies
end

function EnemyService:Init()
	print("[EnemyService] Initializing...")
	Remotes:InitServer()
end

function EnemyService:Start()
	print("[EnemyService] Starting...")

	for _, obj in workspace:GetDescendants() do
		if obj:IsA("Model") then
			for typeName in EnemyConfig.Types do
				if obj.Name == typeName or CollectionService:HasTag(obj, typeName) then
					self:RegisterEnemy(obj, typeName)
					break
				end
			end
		end
	end

	local iframeRemote = Remotes:GetEvent("IFrameStateChanged")
	if iframeRemote then
		iframeRemote.OnServerEvent:Connect(function(player: Player, isInvincible: boolean)
			if isInvincible then
				local now = tick()
				local lastDash = playerLastDash[player] or 0
				local dashConfig = MovementConfig.Dash
				local minInterval = (dashConfig.Duration + dashConfig.Cooldown) * 0.9
				if now - lastDash >= minInterval then
					playerLastDash[player] = now
					playerIFrames[player] = now + dashConfig.IFrameDuration + 0.1
				end
			end
		end)
	end

	Players.PlayerRemoving:Connect(function(player)
		playerIFrames[player] = nil
		playerLastDash[player] = nil
        -- Optimization: Clear from cache
        playerCache[player] = nil
	end)

    -- Optimization: Cache Players
    local function onCharacterAdded(player, char)
        local root = char:WaitForChild("HumanoidRootPart", 5)
        if root then playerCache[player] = root end
    end

    Players.PlayerAdded:Connect(function(player)
        player.CharacterAdded:Connect(function(char) onCharacterAdded(player, char) end)
        if player.Character then onCharacterAdded(player, player.Character) end
    end)
    for _, p in Players:GetPlayers() do
        p.CharacterAdded:Connect(function(char) onCharacterAdded(p, char) end)
        if p.Character then onCharacterAdded(p, p.Character) end
    end

	RunService.Heartbeat:Connect(function(deltaTime)
		aiUpdateAccumulator += deltaTime
		if aiUpdateAccumulator >= EnemyConfig.AI.UpdateRate then
			local updateDelta = aiUpdateAccumulator
			aiUpdateAccumulator = 0
			for enemyModel, enemyData in activeEnemies do
				if enemyModel and enemyModel.Parent and enemyData.State ~= AIState.Dead then
					local success, err = pcall(function() updateEnemyAI(enemyData, updateDelta) end)
					if not success then warn("[EnemyService] AI update error for", enemyModel.Name, ":", err) end
				end
			end
		end
	end)

	print("[EnemyService] Started with", self:GetEnemyCount(), "enemies")
end

return EnemyService
