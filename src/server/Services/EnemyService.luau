--[[
    EnemyService.luau
    Server-side enemy management and AI.
    
    Responsibilities:
    - Spawn and despawn enemies (NO HUMANOID — attribute-based health)
    - Run AI state machine (Idle, Chase, Attack)
    - Handle enemy attacks on players
    - Track active enemies
    - LinearVelocity-based movement
    - AnimationController for rigged models
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local _PathfindingService = game:GetService("PathfindingService")

-- Wait for shared modules
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local EnemyConfig = require(Shared:WaitForChild("Config"):WaitForChild("EnemyConfig"))
local CombatConfig = require(Shared:WaitForChild("Config"):WaitForChild("CombatConfig"))
local MovementConfig = require(Shared:WaitForChild("Config"):WaitForChild("MovementConfig"))
local EnemyLib = require(Shared:WaitForChild("Lib"):WaitForChild("EnemyLib"))

local EnemyService = {
	Name = "EnemyService",
}

-- AI States
local AIState = {
	Idle = "Idle",
	Chase = "Chase",
	Attack = "Attack",
	LeapAttack = "LeapAttack",
	Hitstun = "Hitstun",
	Dead = "Dead",
}

-- Track all active enemies
-- Key: enemy Model, Value: enemy data table
local activeEnemies: { [Model]: EnemyData } = {}

-- Track player I-frame states (for dodge damage immunity)
-- Stores expiry timestamp (tick()) to prevent client-authoritative indefinite invincibility
local playerIFrames: { [Player]: number } = {}
-- Track last dash time for server-side cooldown enforcement
local playerLastDash: { [Player]: number } = {}

-- Type definition for enemy data
type EnemyData = {
	Model: Model,
	RootPart: BasePart,
	LinearVelocity: LinearVelocity?, -- Movement constraint
	AlignOrientation: AlignOrientation?, -- Facing constraint
	Animator: Animator?, -- For rigged models
	WalkTrack: AnimationTrack?, -- Preloaded walk animation
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
	AggroTime: number, -- When we first saw target
	IsMoving: boolean, -- Track if currently moving (for hysteresis)
	LastMoveTarget: Vector3?, -- Last position we told LinearVelocity to go to
	LastPos: Vector3?, -- For unstuck detection
	LastPosTime: number?, -- For unstuck detection
	AttackTriggered: boolean, -- Whether attack was triggered this attack state
	CurrentAttack: any?, -- Selected attack data from config.Attacks (if multi-attack)
}

-- AI update accumulator
local aiUpdateAccumulator = 0

--[[
    Get the nearest player to an enemy within aggro range
]]
local function getNearestPlayer(enemyPosition: Vector3, aggroRange: number): Player?
	local nearestPlayer: Player? = nil
	local nearestDistance = aggroRange

	for _, player in Players:GetPlayers() do
		local character = player.Character
		if not character then
			continue
		end

		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then
			continue
		end

		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then
			continue
		end

		local distance = (rootPart.Position - enemyPosition).Magnitude
		if distance < nearestDistance then
			nearestDistance = distance
			nearestPlayer = player
		end
	end

	return nearestPlayer
end

--[[
    Get target position from a player
]]
local function getTargetPosition(player: Player): Vector3?
	local character = player.Character
	if not character then
		return nil
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return nil
	end

	return rootPart.Position
end

--[[
    Check if target is still valid (alive and in range)
]]
local function isTargetValid(enemyData: EnemyData): boolean
	if not enemyData.Target then
		return false
	end

	local character = enemyData.Target.Character
	if not character then
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end

	local targetRoot = character:FindFirstChild("HumanoidRootPart")
	if not targetRoot then
		return false
	end

	-- Check if still in chase range
	local distance = (targetRoot.Position - enemyData.RootPart.Position).Magnitude
	if distance > EnemyConfig.Aggro.ChaseRange then
		return false
	end

	return true
end

--[[
    Update pathfinding for an enemy
    NOTE: Pathfinding disabled for now - direct movement is smoother on flat terrain
    Uncomment and call updatePath() in chase state when obstacles are needed
]]
--[[
local function updatePath(enemyData: EnemyData)
	if not enemyData.Target then
		return
	end

	local targetPos = getTargetPosition(enemyData.Target)
	if not targetPos then
		return
	end

	local now = tick()

	-- Only recalculate path periodically
	if now - enemyData.LastPathUpdate < EnemyConfig.AI.PathRecalculateInterval then
		return
	end
	enemyData.LastPathUpdate = now

	-- Create or reuse path
	if not enemyData.Path then
		enemyData.Path = PathfindingService:CreatePath({
			AgentRadius = 2,
			AgentHeight = 5,
			AgentCanJump = false,
			AgentCanClimb = false,
		})
	end

	-- Compute path
	local success, err = pcall(function()
		enemyData.Path:ComputeAsync(enemyData.RootPart.Position, targetPos)
	end)

	if success and enemyData.Path.Status == Enum.PathStatus.Success then
		enemyData.PathWaypoints = enemyData.Path:GetWaypoints()
		enemyData.CurrentWaypointIndex = 2 -- Skip first waypoint (current position)
	else
		-- Pathfinding failed, clear path (will use direct movement)
		enemyData.PathWaypoints = nil
		enemyData.CurrentWaypointIndex = 1
	end
end
--]]

--[[
    Move enemy toward target using direct movement (simpler and smoother)
    Pathfinding disabled for now - works better on flat terrain
]]
local function moveTowardTarget(enemyData: EnemyData)
	if not enemyData.Target then
		return
	end

	local targetPos = getTargetPosition(enemyData.Target)
	if not targetPos then
		return
	end

	local currentPos = enemyData.RootPart.Position
	local fullDiff = targetPos - currentPos
	local horizontalDist = Vector3.new(fullDiff.X, 0, fullDiff.Z).Magnitude
	local verticalDist = math.abs(fullDiff.Y)

	-- Target is on top of us — stop chasing to prevent spinning/launching
	if verticalDist > horizontalDist * 1.5 and verticalDist > 4 then
		if enemyData.IsMoving then
			if enemyData.LinearVelocity then
				enemyData.LinearVelocity.PlaneVelocity = Vector2.zero
			end
			enemyData.IsMoving = false
			enemyData.LastMoveTarget = nil
		end
		return
	end

	local distanceToTarget = horizontalDist

	local stopDistance = enemyData.Config.StopDistanceFromTarget or 2.5
	local startChaseDistance = stopDistance + 1.5 -- Hysteresis buffer to prevent jitter

	-- Already close enough - stop moving
	if distanceToTarget <= stopDistance then
		if enemyData.IsMoving then
			if enemyData.LinearVelocity then
				enemyData.LinearVelocity.PlaneVelocity = Vector2.zero
			end
			enemyData.IsMoving = false
			enemyData.LastMoveTarget = nil
		end
		return
	end

	-- In buffer zone and not moving - stay stopped (hysteresis)
	if not enemyData.IsMoving and distanceToTarget < startChaseDistance then
		return
	end

	-- Check if target moved significantly (more than 2 studs from last move target)
	local needsNewMove = false
	if not enemyData.LastMoveTarget then
		needsNewMove = true
	else
		local targetMovedDistance = (targetPos - enemyData.LastMoveTarget).Magnitude
		if targetMovedDistance > 2 then
			needsNewMove = true
		end
	end

	-- Unstuck Logic: Check if we are moving but stuck in place
	if enemyData.IsMoving then
		if not enemyData.LastPos then
			enemyData.LastPos = currentPos
			enemyData.LastPosTime = tick()
		elseif tick() - enemyData.LastPosTime > 1.0 then
			local distMoved = (currentPos - enemyData.LastPos).Magnitude
			if distMoved < 1.0 then
				-- We are stuck! Apply upward impulse instead of Humanoid.Jump
				enemyData.RootPart.AssemblyLinearVelocity = Vector3.new(0, 30, 0)
				needsNewMove = true
			end
			enemyData.LastPos = currentPos
			enemyData.LastPosTime = tick()
		end
	end

	-- Set LinearVelocity to move toward target
	if needsNewMove and enemyData.LinearVelocity then
		local direction = (targetPos - currentPos)
		direction = Vector3.new(direction.X, 0, direction.Z) -- Horizontal only
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
	if not enemyData.Target then
		return
	end

	local targetPos = getTargetPosition(enemyData.Target)
	if not targetPos then
		return
	end

	local fullDirection = targetPos - enemyData.RootPart.Position
	local horizontalDir = Vector3.new(fullDirection.X, 0, fullDirection.Z)
	local horizontalDist = horizontalDir.Magnitude
	local verticalDist = math.abs(fullDirection.Y)

	-- Skip if target is mostly above/below (on top of us) or too close horizontally
	if horizontalDist < 3 or verticalDist > horizontalDist * 1.5 then
		return
	end

	local direction = horizontalDir

	-- Use AlignOrientation to smoothly rotate toward target (prevents direct CFrame conflicts)
	local targetCFrame = CFrame.lookAt(enemyData.RootPart.Position, enemyData.RootPart.Position + direction)
	if enemyData.AlignOrientation then
		enemyData.AlignOrientation.CFrame = targetCFrame
	else
		-- Fallback: find AlignOrientation on root part
		local align = enemyData.RootPart:FindFirstChild("EnemyAlignOrientation")
		if align then
			(align :: AlignOrientation).CFrame = targetCFrame
			enemyData.AlignOrientation = align :: AlignOrientation
		else
			-- Last resort: direct CFrame
			enemyData.RootPart.CFrame = enemyData.RootPart.CFrame:Lerp(targetCFrame, 0.2)
		end
	end
end

--[[
    Pick a random attack from config.Attacks weighted by Weight field
]]
local function pickWeightedAttack(attacks: { any }, distanceToTarget: number?): any
	-- Filter attacks by range constraints (MinRange/MaxRange)
	local eligible = {}
	for _, atk in attacks do
		local inRange = true
		if distanceToTarget and atk.MinRange and distanceToTarget < atk.MinRange then
			inRange = false
		end
		if distanceToTarget and atk.MaxRange and distanceToTarget > atk.MaxRange then
			inRange = false
		end
		if inRange then
			table.insert(eligible, atk)
		end
	end

	-- Fallback: if no attacks are eligible, use all attacks
	if #eligible == 0 then
		eligible = attacks
	end

	local totalWeight = 0
	for _, atk in eligible do
		totalWeight += (atk.Weight or 1)
	end
	local roll = math.random() * totalWeight
	local cumulative = 0
	for _, atk in eligible do
		cumulative += (atk.Weight or 1)
		if roll <= cumulative then
			return atk
		end
	end
	return eligible[1]
end

--[[
    Apply a speed curve to an animation track over its duration.
    SpeedCurve is an array of {time_fraction, speed} keypoints, linearly interpolated.
]]
local function applySpeedCurve(track: AnimationTrack, duration: number, curve: { { number } })
	task.spawn(function()
		local startTime = tick()
		while tick() - startTime < duration do
			local elapsed = tick() - startTime
			local t = math.clamp(elapsed / duration, 0, 1)

			-- Find surrounding keypoints and lerp
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
    Perform a leap attack (multi-phase: wind-up -> jump -> fly -> land slam)
    Used for gap-closing abilities like the Brute's LeapSlam
]]
local function performLeapAttack(enemyData: EnemyData)
	if not enemyData.Target then
		return
	end

	local target = enemyData.Target
	local attackData = enemyData.CurrentAttack
	if not attackData then
		return
	end

	local windupDuration = attackData.WindupDuration or 1.2
	local flightDuration = attackData.FlightDuration or 0.6
	local flightHeight = attackData.FlightHeight or 25
	local landDuration = attackData.LandDuration or 0.8
	local attackDamage = attackData.Damage or 25
	local hitRadius = attackData.HitRadius or 20
	local vfxType = attackData.VFXType or "LeapSlam"

	local rootPart = enemyData.RootPart
	if not rootPart or not rootPart.Parent then
		return
	end

	-- Stop all movement
	if enemyData.LinearVelocity then
		enemyData.LinearVelocity.PlaneVelocity = Vector2.zero
	end

	-- Face target before wind-up
	faceTarget(enemyData)

	-- === PHASE 1: WIND-UP (slow crouch animation) ===
	local windupTrack = nil
	if attackData.WindupAnimId and enemyData.Animator then
		pcall(function()
			local anim = Instance.new("Animation")
			anim.AnimationId = attackData.WindupAnimId
			windupTrack = enemyData.Animator:LoadAnimation(anim)
			windupTrack.Priority = Enum.AnimationPriority.Action4
			windupTrack:Play()
			windupTrack:AdjustSpeed(attackData.WindupAnimSpeed or 0.4)
		end)
	end

	-- Fire wind-up VFX event
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

	-- Wait for wind-up to complete
	task.wait(windupDuration)

	-- Validate still alive
	if not rootPart or not rootPart.Parent or enemyData.State == AIState.Dead then
		if windupTrack then
			windupTrack:Stop()
		end
		return
	end

	-- === PHASE 2: LAUNCH + FLIGHT ===
	-- Get target's current position for landing
	local targetPos = getTargetPosition(target)
	if not targetPos then
		if windupTrack then
			windupTrack:Stop()
		end
		enemyData.State = AIState.Chase
		return
	end

	-- Stop wind-up, play mid-air loop
	if windupTrack then
		windupTrack:Stop(0.1)
	end

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

	-- Disable gravity and move through the air
	local startPos = rootPart.Position
	local landingPos = targetPos -- Aim for player's current position

	-- Temporarily make the enemy anchored for flight control
	local wasAnchored = rootPart.Anchored
	rootPart.Anchored = true
	if enemyData.LinearVelocity then
		enemyData.LinearVelocity.PlaneVelocity = Vector2.zero
	end

	-- Animate flight arc (parabolic: up at start, down at end)
	local flightStart = tick()
	while true do
		local elapsed = tick() - flightStart
		local t = math.clamp(elapsed / flightDuration, 0, 1)
		if t >= 1 then
			break
		end

		-- Parabolic height: peaks at t=0.5
		local heightT = 4 * t * (1 - t) -- 0 at start/end, 1 at peak
		local currentHeight = flightHeight * heightT

		-- Horizontal lerp from start to landing
		local horizontalPos = startPos:Lerp(landingPos, t)

		-- Set position with height offset
		rootPart.CFrame = CFrame.new(
			horizontalPos.X,
			math.max(startPos.Y, landingPos.Y) + currentHeight,
			horizontalPos.Z
		) * CFrame.new(0, 0, 0) -- Keep orientation

		-- Face the landing spot
		local lookDir = (landingPos - rootPart.Position)
		if lookDir.Magnitude > 1 then
			local lookCFrame =
				CFrame.lookAt(rootPart.Position, Vector3.new(landingPos.X, rootPart.Position.Y, landingPos.Z))
			rootPart.CFrame = lookCFrame + (rootPart.Position - lookCFrame.Position)
		end

		task.wait()
	end

	-- === PHASE 3: LANDING ===
	-- Restore physics
	rootPart.Anchored = wasAnchored

	-- Stop mid-air anim, play landing slam
	if midairTrack then
		midairTrack:Stop(0.1)
	end

	if attackData.LandAnimId and enemyData.Animator then
		pcall(function()
			local anim = Instance.new("Animation")
			anim.AnimationId = attackData.LandAnimId
			local landTrack = enemyData.Animator:LoadAnimation(anim)
			landTrack.Priority = Enum.AnimationPriority.Action4
			landTrack:Play()
		end)
	end

	-- Raycast to find ground at landing position
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = CollectionService:GetTagged(CombatConfig.Targeting.TargetTag)
	local rayOrigin = Vector3.new(landingPos.X, rootPart.Position.Y + 5, landingPos.Z)
	local rayResult = workspace:Raycast(rayOrigin, Vector3.new(0, -50, 0), rayParams)
	local impactPos = if rayResult then rayResult.Position else landingPos

	-- Snap to ground
	rootPart.CFrame = CFrame.new(impactPos.X, impactPos.Y + 3, impactPos.Z)
		* CFrame.Angles(0, rootPart.CFrame:ToEulerAnglesYXZ())

	-- Fire landing VFX event
	if enemyAttackRemote then
		enemyAttackRemote:FireAllClients({
			Enemy = enemyData.Model,
			Target = target,
			HitPosition = impactPos,
			Damage = attackDamage,
			AttackType = vfxType, -- "LeapSlam"
			IsSlam = true,
		})
	end

	-- Hit detection at landing point
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if not character then
			continue
		end
		local targetRoot = character:FindFirstChild("HumanoidRootPart")
		if not targetRoot then
			continue
		end

		local dist = (targetRoot.Position - impactPos).Magnitude
		if dist > hitRadius then
			continue
		end

		local targetHumanoid = character:FindFirstChildOfClass("Humanoid")
		if not targetHumanoid or targetHumanoid.Health <= 0 then
			continue
		end

		-- Check I-frames
		local iframeExpiry = playerIFrames[player]
		if iframeExpiry and tick() < iframeExpiry then
			local damageBlockedRemote = Remotes:GetEvent("DamageBlocked")
			if damageBlockedRemote then
				damageBlockedRemote:FireClient(player, {
					Enemy = enemyData.Model,
					Position = targetRoot.Position,
					DamageBlocked = attackDamage,
				})
			end
			continue
		end

		-- Apply damage
		local damage = attackDamage
		local resistance = character:GetAttribute("DamageResistance") or 0
		if resistance > 0 then
			damage = damage * (1 - math.clamp(resistance, 0, 1))
		end

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

		if damage > 0 then
			targetHumanoid:TakeDamage(damage)
		end

		-- Apply knockback (stronger for leap slam)
		local knockbackDir = (targetRoot.Position - impactPos)
		knockbackDir = Vector3.new(knockbackDir.X, 0.5, knockbackDir.Z).Unit
		targetRoot.AssemblyLinearVelocity = targetRoot.AssemblyLinearVelocity + knockbackDir * 35
	end

	-- Recovery period then return to chase
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
    Perform enemy attack on player
]]
local function performAttack(enemyData: EnemyData)
	if not enemyData.Target then
		return
	end

	local target = enemyData.Target
	local config = enemyData.Config
	local attackData = enemyData.CurrentAttack -- nil for non-multi-attack enemies

	local windup = if attackData then attackData.Windup else (config.AttackWindup or 0.3)
	local attackDamage = if attackData then attackData.Damage else (config.Damage or 5)
	local forwardDist = if attackData then attackData.ForwardDist else 4
	local hitRadius = if attackData then attackData.HitRadius else 15
	local vfxType = if attackData then attackData.VFXType else nil

	-- Apply damage after windup
	task.delay(windup, function()
		-- 1. Validate Enemy State
		if not enemyData.RootPart or not enemyData.RootPart.Parent or enemyData.State == AIState.Dead then
			return
		end

		-- 2. Calculate Impact Position (In front of enemy, on the ground)
		local impactPos = enemyData.RootPart.Position + (enemyData.RootPart.CFrame.LookVector * forwardDist)

		-- Raycast down to find actual floor (exclude enemies)
		local rayParams = RaycastParams.new()
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		rayParams.FilterDescendantsInstances = CollectionService:GetTagged(CombatConfig.Targeting.TargetTag)
		local rayOrigin = Vector3.new(impactPos.X, enemyData.RootPart.Position.Y + 5, impactPos.Z)
		local rayResult = workspace:Raycast(rayOrigin, Vector3.new(0, -20, 0), rayParams)
		if rayResult then
			impactPos = rayResult.Position
		else
			-- Fallback: estimate ground from root part
			impactPos = Vector3.new(impactPos.X, enemyData.RootPart.Position.Y - 3, impactPos.Z)
		end

		-- 3. Fire VFX Event (Always happens if enemy is alive)
		local enemyAttackRemote = Remotes:GetEvent("EnemyAttack")
		if enemyAttackRemote then
			enemyAttackRemote:FireAllClients({
				Enemy = enemyData.Model,
				Target = target,
				HitPosition = impactPos,
				Damage = attackDamage,
				AttackType = vfxType, -- "Slam", "Swing", or nil
				IsSlam = (vfxType == "Slam"), -- Backward compat for client
			})
		end

		-- 4. Hit Detection (Simple radius check around impact point OR target check)
		-- Re-check target is valid
		local character = target.Character
		if not character then
			return
		end
		local targetRoot = character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("Root")
		if not targetRoot then
			return
		end

		-- Check distance to IMPACT point
		local distToImpact = (targetRoot.Position - impactPos).Magnitude

		-- Fallback: Also check direct distance if they are hugging the enemy
		local distToEnemy = (targetRoot.Position - enemyData.RootPart.Position).Magnitude

		if distToImpact > hitRadius and distToEnemy > (config.AttackRange or 5) + 2 then
			return -- Missed
		end

		-- 5. Deal Damage
		local targetHumanoid = character:FindFirstChildOfClass("Humanoid")
		if not targetHumanoid or targetHumanoid.Health <= 0 then
			return
		end

		-- Check I-frames
		local iframeExpiry = playerIFrames[target]
		if iframeExpiry and tick() < iframeExpiry then
			-- Dodged
			local damageBlockedRemote = Remotes:GetEvent("DamageBlocked")
			if damageBlockedRemote then
				damageBlockedRemote:FireClient(target, {
					Enemy = enemyData.Model,
					Position = targetRoot.Position,
					DamageBlocked = attackDamage,
				})
			end
			return
		end

		-- Apply Damage
		local damage = attackDamage

		-- Resistance
		local resistance = character:GetAttribute("DamageResistance") or 0
		if resistance > 0 then
			damage = damage * (1 - math.clamp(resistance, 0, 1))
		end

		-- Shield
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

		if damage > 0 then
			targetHumanoid:TakeDamage(damage)
		end

		-- Apply knockback
		local knockbackDir = (targetRoot.Position - enemyData.RootPart.Position)
		knockbackDir = Vector3.new(knockbackDir.X, 0.3, knockbackDir.Z).Unit
		targetRoot.AssemblyLinearVelocity = targetRoot.AssemblyLinearVelocity + knockbackDir * 20
	end)
end

--[[
    Update AI state machine for a single enemy
]]
local function updateEnemyAI(enemyData: EnemyData, deltaTime: number)
	local config = enemyData.Config
	local now = tick()
	local oldState = enemyData.State

	-- Skip if dead
	if not EnemyLib:IsAlive(enemyData.Model) then
		if enemyData.State ~= AIState.Dead then
			enemyData.State = AIState.Dead
			local stateRemote = Remotes:GetEvent("EnemyStateChanged")
			if stateRemote then
				stateRemote:FireAllClients(enemyData.Model, AIState.Dead)
			end
		end
		return
	end

	-- Handle hitstun
	if enemyData.State == AIState.Hitstun then
		if now >= enemyData.HitstunEndTime then
			enemyData.State = AIState.Idle
		else
			return -- Still stunned, skip AI
		end
	end

	-- State machine
	if enemyData.State == AIState.Idle then
		-- Look for players
		local nearestPlayer =
			getNearestPlayer(enemyData.RootPart.Position, config.AggroRange or EnemyConfig.Aggro.DetectionRange)

		if nearestPlayer then
			enemyData.Target = nearestPlayer
			enemyData.State = AIState.Chase
			enemyData.AggroTime = now
			enemyData.LastPathUpdate = 0 -- Force path recalculation
			-- Start walk animation
			if enemyData.WalkTrack and not enemyData.WalkTrack.IsPlaying then
				enemyData.WalkTrack:Play()
			end
		end
	elseif enemyData.State == AIState.Chase then
		-- Validate target
		if not isTargetValid(enemyData) then
			enemyData.Target = nil
			enemyData.State = AIState.Idle
			enemyData.IsMoving = false
			enemyData.LastMoveTarget = nil
			if enemyData.LinearVelocity then
				enemyData.LinearVelocity.PlaneVelocity = Vector2.zero
			end
			-- Stop walk animation
			if enemyData.WalkTrack and enemyData.WalkTrack.IsPlaying then
				enemyData.WalkTrack:Stop(0.2)
			end
			return
		end

		-- Check if in attack range
		local targetPos = getTargetPosition(enemyData.Target)
		if targetPos then
			local distanceToTarget = (targetPos - enemyData.RootPart.Position).Magnitude
			local distance = distanceToTarget
			local attackRange = config.AttackRange or 4

			-- DEBUG: Print distance and attack state occasionally
			if enemyData.EnemyType == "Brute" and math.random() < 0.05 then
				-- print("[EnemyService][Brute] Dist:", distance, "Range:", attackRange, "Cooldown:", now - enemyData.LastAttackTime)
			end

			if distance <= attackRange then
				-- In attack range, switch to attack state
				if now - enemyData.LastAttackTime >= (config.AttackCooldown or 1.5) then
					-- print("[EnemyService] Brute entering ATTACK state!")
					enemyData.State = AIState.Attack
					enemyData.LastAttackTime = now
					enemyData.AttackTriggered = false -- Reset attack trigger flag
					-- Stop movement and walk animation when attacking
					enemyData.IsMoving = false
					enemyData.LastMoveTarget = nil
					if enemyData.LinearVelocity then
						enemyData.LinearVelocity.PlaneVelocity = Vector2.zero
					end
					if enemyData.WalkTrack and enemyData.WalkTrack.IsPlaying then
						enemyData.WalkTrack:Stop(0.15)
					end
				end
			else
				-- Move toward target
				moveTowardTarget(enemyData)
				-- Face the target while chasing
				faceTarget(enemyData)
			end
		end
	elseif enemyData.State == AIState.Attack then
		-- Face target
		faceTarget(enemyData)

		-- Perform attack (only once per attack state entry)
		if not enemyData.AttackTriggered then
			enemyData.AttackTriggered = true

			-- Select attack from Attacks table if available
			local attackData = nil
			if config.Attacks then
				-- Calculate distance for range-filtered attack selection
				local attackTargetPos = getTargetPosition(enemyData.Target)
				local atkDist = if attackTargetPos
					then (attackTargetPos - enemyData.RootPart.Position).Magnitude
					else nil
				attackData = pickWeightedAttack(config.Attacks, atkDist)
				enemyData.CurrentAttack = attackData
			else
				enemyData.CurrentAttack = nil
			end

			-- Determine animation ID and duration from attack data or legacy config
			local animId = if attackData then attackData.AnimationId else config.SlamAnimationId
			local attackDuration = if attackData then attackData.Duration else (config.AttackDuration or 0.6)

			-- Play animation (protected so it doesn't block attack logic)
			if animId and enemyData.Animator then
				local ok, animErr = pcall(function()
					local animation = Instance.new("Animation")
					animation.AnimationId = animId
					local track = enemyData.Animator:LoadAnimation(animation)
					track.Priority = Enum.AnimationPriority.Action
					track:Play()

					-- Apply speed curve if defined (e.g. Swing: slow start → fast finish)
					if attackData and attackData.SpeedCurve then
						applySpeedCurve(track, attackDuration, attackData.SpeedCurve)
					end
				end)
				if not ok then
					warn("[EnemyService] Animation error for", enemyData.EnemyType, ":", animErr)
				end
			end

			-- Check if this is a leap-type attack (needs special handling)
			if attackData and attackData.Type == "Leap" then
				-- Switch to LeapAttack state and run multi-phase attack
				enemyData.State = AIState.LeapAttack
				task.spawn(function()
					performLeapAttack(enemyData)
				end)
			else
				performAttack(enemyData)

				-- Return to chase after attack duration (only schedule once)
				task.delay(attackDuration, function()
					if enemyData.State == AIState.Attack then
						enemyData.State = AIState.Chase
						enemyData.CurrentAttack = nil
						-- Resume walk animation
						if enemyData.WalkTrack and not enemyData.WalkTrack.IsPlaying then
							enemyData.WalkTrack:Play(0.2)
						end
					end
				end)
			end
		end
	end

	-- Broadcast state change if it happened
	if enemyData.State ~= oldState then
		local stateRemote = Remotes:GetEvent("EnemyStateChanged")
		if stateRemote then
			stateRemote:FireAllClients(enemyData.Model, enemyData.State)
		end
	end
end

--[[
    Apply hitstun to an enemy (called when enemy takes damage)
    
    IMPORTANT: This only affects AI state - visual effects are handled client-side
    by EnemyVFXController. Do not manipulate CFrame here.
    
    Knockback velocity is applied by CombatService BEFORE this is called.
    We delay velocity zeroing to let the knockback play out visually.
]]
function EnemyService:ApplyHitstun(enemyModel: Model, duration: number?)
	local enemyData = activeEnemies[enemyModel]
	if not enemyData then
		return
	end

	-- Don't apply hitstun if already dead
	if enemyData.State == AIState.Dead then
		return
	end

	local hitstunDuration = duration or enemyData.Config.HitstunDuration or 0.3

	-- Apply knockback resistance
	local resistance = enemyData.Config.KnockbackResistance or 0
	hitstunDuration = hitstunDuration * (1 - resistance)

	if hitstunDuration > 0 then
		local oldState = enemyData.State
		enemyData.State = AIState.Hitstun
		enemyData.HitstunEndTime = tick() + hitstunDuration

		-- Reset movement state (stops LinearVelocity from being set)
		enemyData.IsMoving = false
		enemyData.LastMoveTarget = nil

		-- Stop walk animation
		if enemyData.WalkTrack and enemyData.WalkTrack.IsPlaying then
			enemyData.WalkTrack:Stop(0.1)
		end

		-- Stop LinearVelocity-driven movement
		if enemyData.LinearVelocity then
			enemyData.LinearVelocity.VectorVelocity = Vector3.zero
		end

		-- IMPORTANT: Delay velocity zeroing to allow knockback to play out
		-- Knockback was already applied by CombatService before this function
		-- Wait 0.15s to let enemy visibly move from knockback before stopping
		local knockbackDuration = 0.15
		task.delay(knockbackDuration, function()
			if not enemyData.RootPart or not enemyData.RootPart.Parent then
				return
			end
			if enemyData.State ~= AIState.Hitstun then
				return -- State changed, don't mess with velocity
			end

			-- Now zero horizontal velocity to stop sliding
			local currentVel = enemyData.RootPart.AssemblyLinearVelocity
			enemyData.RootPart.AssemblyLinearVelocity = Vector3.new(0, math.min(currentVel.Y, 0), 0)
		end)

		-- Broadcast state change
		if oldState ~= AIState.Hitstun then
			local stateRemote = Remotes:GetEvent("EnemyStateChanged")
			if stateRemote then
				stateRemote:FireAllClients(enemyData.Model, AIState.Hitstun)
			end
		end
	end
end

--[[
    Register an existing enemy model (for manually placed enemies)
]]
function EnemyService:RegisterEnemy(enemyModel: Model, enemyType: string?)
	-- Validate model has a root part
	local rootPart = enemyModel:FindFirstChild("HumanoidRootPart")
		or enemyModel:FindFirstChild("Root")
		or enemyModel:FindFirstChild("Torso")
		or enemyModel.PrimaryPart
	if not rootPart then
		warn("[EnemyService] Cannot register enemy without root part:", enemyModel.Name)
		return
	end

	-- Determine enemy type from model name or parameter
	local typeKey = enemyType or enemyModel.Name
	local config = EnemyConfig.Types[typeKey]
	if not config then
		-- Default to Minion if type not found
		config = EnemyConfig.Types.Minion
		typeKey = "Minion"
	end

	-- Apply stats from config with Director difficulty multipliers
	local healthMultiplier = 1.0
	local speedMultiplier = 1.0
	local damageMultiplier = 1.0

	-- Get difficulty multipliers from Director if available
	local DirectorService = _G.DirectorService
	if DirectorService and DirectorService:IsRunning() then
		local multipliers = DirectorService:GetStatMultipliers()
		healthMultiplier = multipliers.Health
		speedMultiplier = multipliers.Speed
		damageMultiplier = multipliers.Damage
	end

	-- Apply scaled stats
	local scaledHealth = math.floor(config.Health * healthMultiplier)
	local scaledSpeed = config.WalkSpeed * speedMultiplier
	local scaledDamage = config.Damage * damageMultiplier

	-- Setup attributes (replaces Humanoid.MaxHealth/Health/WalkSpeed)
	EnemyLib:SetupAttributes(enemyModel, scaledHealth, scaledHealth, scaledSpeed)

	-- Store scaled damage in config copy for this enemy
	local scaledConfig = {}
	for k, v in config do
		scaledConfig[k] = v
	end
	scaledConfig.Damage = scaledDamage

	-- Store multipliers on model for debugging
	enemyModel:SetAttribute("HealthMultiplier", healthMultiplier)
	enemyModel:SetAttribute("DamageMultiplier", damageMultiplier)
	enemyModel:SetAttribute("SpeedMultiplier", speedMultiplier)

	-- Tag as enemy for targeting system
	CollectionService:AddTag(enemyModel, CombatConfig.Targeting.TargetTag)

	-- Set network owner to server (nil) for authoritative physics
	if rootPart:IsA("BasePart") then
		rootPart:SetNetworkOwner(nil)
	end

	-- Disable collision + mass on all animated parts to prevent hopping
	-- Animated limbs pushing against the ground cause bouncing
	for _, part in enemyModel:GetDescendants() do
		if part:IsA("BasePart") then
			part.CollisionGroup = "Enemies"
			part.CanCollide = false
			if part ~= rootPart then
				part.Massless = true
			end
		end
	end

	-- Create invisible collision box from root down to feet
	-- This keeps the model at the correct height without animated parts interfering
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
	-- Position so box bottom sits at feet level
	local yOffset = -distToFeet + boxHeight / 2
	collisionBox.CFrame = rootPart.CFrame * CFrame.new(0, yOffset, 0)
	collisionBox.Parent = enemyModel

	local collisionWeld = Instance.new("WeldConstraint")
	collisionWeld.Part0 = rootPart
	collisionWeld.Part1 = collisionBox
	collisionWeld.Parent = collisionBox

	-- Setup LinearVelocity for movement (replaces Humanoid:MoveTo)
	local attachment = rootPart:FindFirstChild("RootAttachment")
	if not attachment then
		attachment = Instance.new("Attachment")
		attachment.Name = "RootAttachment"
		attachment.Parent = rootPart
	end

	local linearVelocity = Instance.new("LinearVelocity")
	linearVelocity.Name = "EnemyMoveVelocity"
	linearVelocity.Attachment0 = attachment
	linearVelocity.MaxForce = 50000 -- Enough force to move the enemy reliably
	linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	-- Use Plane mode: only constrain XZ velocity, let gravity handle Y naturally
	linearVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	linearVelocity.PrimaryTangentAxis = Vector3.new(1, 0, 0) -- X axis
	linearVelocity.SecondaryTangentAxis = Vector3.new(0, 0, 1) -- Z axis
	linearVelocity.PlaneVelocity = Vector2.zero
	linearVelocity.Parent = rootPart

	-- Add AlignOrientation to keep enemy upright (prevents pendulum swinging)
	-- This replaces the stabilization that Humanoid normally provides
	local alignAttachment = Instance.new("Attachment")
	alignAttachment.Name = "AlignAttachment"
	alignAttachment.Parent = rootPart

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "EnemyAlignOrientation"
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0 = alignAttachment
	alignOrientation.CFrame = rootPart.CFrame -- Initial orientation
	alignOrientation.MaxTorque = math.huge -- Infinite torque to force it upright
	alignOrientation.MaxAngularVelocity = math.huge
	alignOrientation.Responsiveness = 200
	alignOrientation.RigidityEnabled = true -- Force it to be upright INSTANTLY (no spring)
	alignOrientation.Parent = rootPart

	-- Setup AnimationController + Animator (replaces Humanoid for animations)
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

	-- Remove any leftover Humanoid (safety for pre-existing models)
	local existingHumanoid = enemyModel:FindFirstChildOfClass("Humanoid")
	if existingHumanoid then
		existingHumanoid:Destroy()
	end

	-- Preload walk animation if configured
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
		if ok then
			walkTrack = result
		else
			warn("[EnemyService] Walk animation error for", typeKey, ":", result)
		end
	end

	-- Create enemy data
	local enemyData: EnemyData = {
		Model = enemyModel,
		RootPart = rootPart,
		LinearVelocity = linearVelocity,
		AlignOrientation = alignOrientation, -- Keep enemy upright + drive rotation
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

	-- Handle death via IsDead attribute (replaces Humanoid.Died)
	enemyModel:GetAttributeChangedSignal("IsDead"):Connect(function()
		if not enemyModel:GetAttribute("IsDead") then
			return
		end

		enemyData.State = AIState.Dead

		-- Stop movement and animations
		if enemyData.LinearVelocity then
			enemyData.LinearVelocity.PlaneVelocity = Vector2.zero
		end
		if enemyData.WalkTrack and enemyData.WalkTrack.IsPlaying then
			enemyData.WalkTrack:Stop(0)
		end

		-- Fire death event
		local enemyDiedRemote = Remotes:GetEvent("EnemyDied")
		if enemyDiedRemote then
			enemyDiedRemote:FireAllClients({
				Target = enemyModel,
				Killer = enemyData.Target,
				Position = rootPart.Position,
			})
		end

		-- Immediately disable physics interactions that block shots
		for _, part in enemyModel:GetDescendants() do
			if part:IsA("BasePart") then
				part.CanQuery = false
				part.CanTouch = false
				part.CollisionGroup = "Debris"
			end
		end

		-- Cleanup after death animation
		task.delay(EnemyConfig.Death.RagdollDuration, function()
			activeEnemies[enemyModel] = nil

			for _, part in enemyModel:GetDescendants() do
				if part:IsA("BasePart") then
					part.CanCollide = false
				end
			end

			task.delay(EnemyConfig.Death.FadeOutDuration, function()
				if enemyModel and enemyModel.Parent then
					enemyModel:Destroy()
				end
			end)
		end)
	end)

	-- Apply hitstun when Health attribute changes (replaces Humanoid.HealthChanged)
	local lastHealth = scaledHealth
	enemyModel:GetAttributeChangedSignal("Health"):Connect(function()
		local newHealth: number = (enemyModel:GetAttribute("Health") :: number?) or 0
		if newHealth < lastHealth then
			EnemyService:ApplyHitstun(enemyModel)
		end
		lastHealth = newHealth
	end)

	print("[EnemyService] Registered enemy:", enemyModel.Name, "Type:", typeKey, "(Humanoid-free)")
	return enemyData
end

--[[
    Spawn a new enemy at a position
]]
function EnemyService:SpawnEnemy(enemyType: string, position: Vector3, parent: Instance?): Model?
	local config = EnemyConfig.Types[enemyType]
	if not config then
		warn("[EnemyService] Unknown enemy type:", enemyType)
		return nil
	end

	-- Check enemy cap
	local enemyCount = 0
	for _ in activeEnemies do
		enemyCount += 1
	end
	if enemyCount >= EnemyConfig.AI.MaxActiveEnemies then
		warn("[EnemyService] Max enemy cap reached")
		return nil
	end

	-- Create basic model
	-- Priority: Load from Assets -> Fallback to Placeholder
	local enemyModel: Model? = nil
	local assetsFolder = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Assets")
	local enemiesFolder = assetsFolder:FindFirstChild("Enemies")

	if enemiesFolder then
		local asset = enemiesFolder:FindFirstChild(enemyType)
		if asset then
			enemyModel = asset:Clone()
		end
	end

	if not enemyModel then
		-- Fallback: Create placeholder model
		enemyModel = Instance.new("Model")
		enemyModel.Name = enemyType

		-- Create basic parts
		local torso = Instance.new("Part")
		torso.Name = "HumanoidRootPart"
		torso.Size = Vector3.new(2, 2, 1)
		torso.Position = position
		torso.Anchored = false
		torso.CanCollide = true

		-- Color based on type
		if enemyType == "Brute" then
			torso.Color = Color3.fromRGB(200, 50, 50) -- Dark Red
			torso.Size = Vector3.new(3, 3, 1.5) -- Bigger
		elseif enemyType == "Shooter" then
			torso.Color = Color3.fromRGB(200, 200, 50) -- Yellow
		else
			torso.Color = Color3.fromRGB(150, 150, 150) -- Grey Minion
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

		-- Weld head to torso
		local weld = Instance.new("Weld")
		weld.Part0 = torso
		weld.Part1 = head
		weld.C0 = CFrame.new(0, 1.5, 0)
		weld.Parent = torso

		enemyModel.PrimaryPart = torso
	end

	enemyModel.Parent = parent or workspace

	-- Ensure position is set correctly (especially for loaded models)
	if enemyModel and enemyModel.PrimaryPart then
		-- Calculate hip height / spawn offset to prevent spawning in ground
		local cframe, size = enemyModel:GetBoundingBox()
		local heightOffset = size.Y / 2 + 1 -- Half height + 1 stud buffer

		-- Raycast down to find ground if we were given a vague position
		-- (Optional refinement, but for now just offset up)

		enemyModel:PivotTo(CFrame.new(position + Vector3.new(0, heightOffset, 0)))
	end

	-- Register the enemy (sets up attributes, LinearVelocity, AnimationController)
	-- Cast to Model since we know it's not nil here (or we returned early/handled it)
	-- But to be safe for the type checker:
	if enemyModel then
		self:RegisterEnemy(enemyModel, enemyType)
	end

	return enemyModel
end

--[[
    Get count of active enemies
]]
function EnemyService:GetEnemyCount(): number
	local count = 0
	for _ in activeEnemies do
		count += 1
	end
	return count
end

--[[
    Get all active enemies
]]
function EnemyService:GetActiveEnemies(): { [Model]: EnemyData }
	return activeEnemies
end

--[[
    Initialize the service
]]
function EnemyService:Init()
	print("[EnemyService] Initializing...")

	-- Initialize remotes
	Remotes:InitServer()
end

--[[
    Start the service
]]
function EnemyService:Start()
	print("[EnemyService] Starting...")

	-- Register existing enemies in workspace
	-- Look for models tagged with "Enemy" or matching enemy type names
	for _, obj in workspace:GetDescendants() do
		if obj:IsA("Model") then
			-- Check if it's tagged as an enemy type or has IsEnemy attribute
			for typeName in EnemyConfig.Types do
				if obj.Name == typeName or CollectionService:HasTag(obj, typeName) then
					self:RegisterEnemy(obj, typeName)
					break
				end
			end
		end
	end

	-- Listen for I-frame state changes from clients
	local iframeRemote = Remotes:GetEvent("IFrameStateChanged")
	if iframeRemote then
		iframeRemote.OnServerEvent:Connect(function(player: Player, isInvincible: boolean)
			if isInvincible then
				local now = tick()
				local lastDash = playerLastDash[player] or 0
				local dashConfig = MovementConfig.Dash
				local minInterval = (dashConfig.Duration + dashConfig.Cooldown) * 0.9 -- 10% grace period

				-- Enforce cooldown and max duration on server
				if now - lastDash >= minInterval then
					playerLastDash[player] = now
					playerIFrames[player] = now + dashConfig.IFrameDuration + 0.1 -- 0.1s grace for latency
				end
			else
				-- Don't clear i-frames early — let them expire naturally via timestamp
				-- Clearing here killed i-frames before slow attacks (like Brute slam) landed
			end
		end)
	end

	-- Cleanup I-frame state when player leaves
	Players.PlayerRemoving:Connect(function(player)
		playerIFrames[player] = nil
		playerLastDash[player] = nil
	end)

	-- AI update loop
	RunService.Heartbeat:Connect(function(deltaTime)
		aiUpdateAccumulator += deltaTime

		-- Update at configured rate
		if aiUpdateAccumulator >= EnemyConfig.AI.UpdateRate then
			local updateDelta = aiUpdateAccumulator
			aiUpdateAccumulator = 0

			-- Update all enemies
			for enemyModel, enemyData in activeEnemies do
				if enemyModel and enemyModel.Parent and enemyData.State ~= AIState.Dead then
					local success, err = pcall(function()
						updateEnemyAI(enemyData, updateDelta)
					end)
					if not success then
						warn("[EnemyService] AI update error for", enemyModel.Name, ":", err)
					end
				end
			end
		end
	end)

	print("[EnemyService] Started with", self:GetEnemyCount(), "enemies")
end

return EnemyService
