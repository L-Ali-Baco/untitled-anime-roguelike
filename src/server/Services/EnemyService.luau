--[[
    EnemyService.luau
    Server-side enemy management and AI.
    
    Responsibilities:
    - Spawn and despawn enemies
    - Run AI state machine (Idle, Chase, Attack)
    - Handle enemy attacks on players
    - Track active enemies
    - PathfindingService integration
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")

-- Wait for shared modules
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local EnemyConfig = require(Shared:WaitForChild("Config"):WaitForChild("EnemyConfig"))
local CombatConfig = require(Shared:WaitForChild("Config"):WaitForChild("CombatConfig"))

local EnemyService = {
	Name = "EnemyService",
}

-- AI States
local AIState = {
	Idle = "Idle",
	Chase = "Chase",
	Attack = "Attack",
	Hitstun = "Hitstun",
	Dead = "Dead",
}

-- Track all active enemies
-- Key: enemy Model, Value: enemy data table
local activeEnemies: { [Model]: EnemyData } = {}

-- Track player I-frame states (for dodge damage immunity)
local playerIFrames: { [Player]: boolean } = {}

-- Type definition for enemy data
type EnemyData = {
	Model: Model,
	Humanoid: Humanoid,
	RootPart: BasePart,
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
	LastMoveTarget: Vector3?, -- Last position we told MoveTo to go to
	AttackTriggered: boolean, -- Whether attack was triggered this attack state
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
	local distanceToTarget = (targetPos - currentPos).Magnitude

	local stopDistance = enemyData.Config.StopDistanceFromTarget or 2.5
	local startChaseDistance = stopDistance + 1.5 -- Hysteresis buffer to prevent jitter

	-- Already close enough - stop moving
	if distanceToTarget <= stopDistance then
		if enemyData.IsMoving then
			enemyData.Humanoid:MoveTo(currentPos)
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
				-- We are stuck! Try jumping
				enemyData.Humanoid.Jump = true
				-- Try moving slightly to the side next update
				needsNewMove = true
			end
			enemyData.LastPos = currentPos
			enemyData.LastPosTime = tick()
		end
	end

	-- Only call MoveTo if we need to update destination
	if needsNewMove then
		enemyData.Humanoid:MoveTo(targetPos)
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

	local direction = (targetPos - enemyData.RootPart.Position)
	direction = Vector3.new(direction.X, 0, direction.Z)

	if direction.Magnitude < 0.1 then
		return
	end

	-- Smoothly rotate toward target
	local targetCFrame = CFrame.lookAt(enemyData.RootPart.Position, enemyData.RootPart.Position + direction)
	enemyData.RootPart.CFrame = enemyData.RootPart.CFrame:Lerp(targetCFrame, 0.2)
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

	-- Apply damage after windup
	task.delay(config.AttackWindup or 0.3, function()
		-- Re-check target is still valid and in range
		if not enemyData.Target or enemyData.State == AIState.Dead then
			return
		end

		-- Re-fetch character (player may have respawned)
		local character = target.Character
		if not character then
			return
		end

		local targetHumanoid = character:FindFirstChildOfClass("Humanoid")
		if not targetHumanoid or targetHumanoid.Health <= 0 then
			return
		end

		local targetRoot = character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("Root")
		if not targetRoot then
			return
		end

		-- Check enemy root part still exists
		if not enemyData.RootPart or not enemyData.RootPart.Parent then
			return
		end

		local distance = (targetRoot.Position - enemyData.RootPart.Position).Magnitude
		if distance > (config.AttackRange or 4) * 1.5 then
			return -- Target moved out of range
		end

		-- Check if player has I-frames (dodge immunity)
		if playerIFrames[target] then
			-- Player dodged! Send blocked event for VFX
			local damageBlockedRemote = Remotes:GetEvent("DamageBlocked")
			if damageBlockedRemote then
				damageBlockedRemote:FireClient(target, {
					Enemy = enemyData.Model,
					Position = targetRoot.Position,
					DamageBlocked = config.Damage or 5,
				})
			end
			return -- Don't deal damage
		end

		-- Deal damage (Shield Logic)
		local damage = config.Damage or 5

		-- Apply Damage Resistance
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

		-- Apply knockback to player
		local knockbackDir = (targetRoot.Position - enemyData.RootPart.Position)
		knockbackDir = Vector3.new(knockbackDir.X, 0.3, knockbackDir.Z).Unit
		targetRoot.AssemblyLinearVelocity = targetRoot.AssemblyLinearVelocity + knockbackDir * 10

		-- Fire event for client VFX
		local enemyAttackRemote = Remotes:GetEvent("EnemyAttack")
		if enemyAttackRemote then
			enemyAttackRemote:FireAllClients({
				Enemy = enemyData.Model,
				Target = target,
				HitPosition = targetRoot.Position,
				Damage = config.Damage or 5,
			})
		end
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
	if enemyData.Humanoid.Health <= 0 then
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
		end
	elseif enemyData.State == AIState.Chase then
		-- Validate target
		if not isTargetValid(enemyData) then
			enemyData.Target = nil
			enemyData.State = AIState.Idle
			enemyData.IsMoving = false
			enemyData.LastMoveTarget = nil
			enemyData.Humanoid:MoveTo(enemyData.RootPart.Position) -- Stop moving
			return
		end

		-- Check if in attack range
		local targetPos = getTargetPosition(enemyData.Target)
		if targetPos then
			local distance = (targetPos - enemyData.RootPart.Position).Magnitude
			local attackRange = config.AttackRange or 4

			if distance <= attackRange then
				-- In attack range, switch to attack state
				if now - enemyData.LastAttackTime >= (config.AttackCooldown or 1.5) then
					enemyData.State = AIState.Attack
					enemyData.LastAttackTime = now
					enemyData.AttackTriggered = false -- Reset attack trigger flag
					-- Stop movement when attacking
					enemyData.IsMoving = false
					enemyData.LastMoveTarget = nil
					enemyData.Humanoid:MoveTo(enemyData.RootPart.Position)
				end
			else
				-- Move toward target
				moveTowardTarget(enemyData)
			end
		end
	elseif enemyData.State == AIState.Attack then
		-- Face target
		faceTarget(enemyData)

		-- Perform attack (only once per attack state entry)
		if not enemyData.AttackTriggered then
			enemyData.AttackTriggered = true
			performAttack(enemyData)
		end

		-- Return to chase after attack duration
		local attackDuration = config.AttackDuration or 0.6
		task.delay(attackDuration, function()
			if enemyData.State == AIState.Attack then
				enemyData.State = AIState.Chase
			end
		end)
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

		-- Reset movement state (stops MoveTo from being called)
		enemyData.IsMoving = false
		enemyData.LastMoveTarget = nil

		-- Stop the Humanoid from moving on its own
		-- MoveTo to current position stops pathfinding without affecting velocity
		local currentPos = enemyData.RootPart.Position
		enemyData.Humanoid:MoveTo(currentPos)

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
	-- Validate model
	local humanoid = enemyModel:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		warn("[EnemyService] Cannot register enemy without Humanoid:", enemyModel.Name)
		return
	end

	local rootPart = enemyModel:FindFirstChild("HumanoidRootPart")
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

	humanoid.MaxHealth = scaledHealth
	humanoid.Health = scaledHealth
	humanoid.WalkSpeed = scaledSpeed

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
	-- This prevents client-side physics interference and teleportation issues
	if rootPart:IsA("BasePart") then
		rootPart:SetNetworkOwner(nil)
	end

	-- Apply collision group
	for _, part in enemyModel:GetDescendants() do
		if part:IsA("BasePart") then
			part.CollisionGroup = "Enemies"
		end
	end

	-- Create enemy data (use scaledConfig for proper damage values)
	local enemyData: EnemyData = {
		Model = enemyModel,
		Humanoid = humanoid,
		RootPart = rootPart,
		EnemyType = typeKey,
		Config = scaledConfig, -- Use scaled config with difficulty-adjusted damage
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

	-- Handle death
	humanoid.Died:Connect(function()
		enemyData.State = AIState.Dead

		-- Fire death event
		local enemyDiedRemote = Remotes:GetEvent("EnemyDied")
		if enemyDiedRemote then
			enemyDiedRemote:FireAllClients({
				Target = enemyModel,
				Killer = enemyData.Target, -- Last player who hit
				Position = rootPart.Position,
			})
		end

		-- Immediately disable physics interactions that block shots
		for _, part in enemyModel:GetDescendants() do
			if part:IsA("BasePart") then
				part.CanQuery = false -- Don't block raycasts
				part.CanTouch = false -- Don't trigger touches
				part.CollisionGroup = "Debris" -- Optional: Move to debris group if it exists
			end
		end

		-- Cleanup after ragdoll
		task.delay(EnemyConfig.Death.RagdollDuration, function()
			activeEnemies[enemyModel] = nil

			-- Fade out and destroy
			for _, part in enemyModel:GetDescendants() do
				if part:IsA("BasePart") then
					part.CanCollide = false
				end
			end

			-- Destroy model
			task.delay(EnemyConfig.Death.FadeOutDuration, function()
				if enemyModel and enemyModel.Parent then
					enemyModel:Destroy()
				end
			end)
		end)
	end)

	-- Apply hitstun when damaged
	humanoid.HealthChanged:Connect(function(newHealth)
		if newHealth < humanoid.MaxHealth then
			EnemyService:ApplyHitstun(enemyModel)
		end
	end)

	print("[EnemyService] Registered enemy:", enemyModel.Name, "Type:", typeKey)
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

	-- Create basic humanoid model
	-- In production, you'd clone from a prefab in ReplicatedStorage
	local enemyModel = Instance.new("Model")
	enemyModel.Name = enemyType

	-- Create humanoid
	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = enemyModel

	-- Create basic parts (placeholder - replace with actual model)
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
	enemyModel.Parent = parent or workspace

	-- Register the enemy
	self:RegisterEnemy(enemyModel, enemyType)

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
	-- Look for models tagged with "Enemy" that aren't TrainingDummy
	for _, obj in workspace:GetDescendants() do
		if obj:IsA("Model") and obj:FindFirstChildOfClass("Humanoid") then
			-- Check if it's tagged as an enemy type
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
			playerIFrames[player] = isInvincible or nil -- Store true or remove entry
		end)
	end

	-- Cleanup I-frame state when player leaves
	Players.PlayerRemoving:Connect(function(player)
		playerIFrames[player] = nil
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
