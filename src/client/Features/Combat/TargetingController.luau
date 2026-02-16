--[[
    TargetingController.luau
    Auto-targeting system for mobile-friendly combat.
    Finds nearest enemy within range and cone angle.
    Provides soft-lock for attacks to "bend" toward target.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Signal = require(ReplicatedStorage.Packages.Signal)
local CombatConfig = require(ReplicatedStorage.Shared.Config.CombatConfig)
local EnemyLib = require(ReplicatedStorage.Shared.Lib.EnemyLib)

local TargetingController = {}
TargetingController.Name = "TargetingController"

-- Config shorthand
local TargetConfig = CombatConfig.Targeting

-- References
local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

-- State
local currentTarget: Model? = nil
local lastUpdateTime = 0

-- Debug mode (set to true to see targeting info)
local DEBUG_TARGETING = false

-- Signals
TargetingController.OnTargetChanged = Signal.new() -- Fires (newTarget, oldTarget)
TargetingController.OnTargetLost = Signal.new() -- Fires when target dies/leaves range

-- Connections
local connections: { RBXScriptConnection } = {}

--[[
    Get all valid targets (enemies)
]]
local function getValidTargets(): { Model }
	local targets = {}

	-- Get all tagged enemies
	local tagged = CollectionService:GetTagged(TargetConfig.TargetTag)
	for _, instance in tagged do
		if instance:IsA("Model") then
			if EnemyLib:IsAlive(instance) then
				table.insert(targets, instance)
			end
		end
	end

	-- Also get training dummies
	local dummies = CollectionService:GetTagged("TrainingDummy")
	for _, instance in dummies do
		if instance:IsA("Model") then
			if EnemyLib:IsAlive(instance) then
				-- Avoid duplicates
				local found = false
				for _, t in targets do
					if t == instance then
						found = true
						break
					end
				end
				if not found then
					table.insert(targets, instance)
				end
			end
		end
	end

	-- Fallback: scan workspace for models with "Dummy" or "Enemy" in name
	for _, child in Workspace:GetChildren() do
		if child:IsA("Model") then
			local name = child.Name
			if name:find("Dummy") or name:find("Enemy") or name:find("Target") then
				if EnemyLib:IsAlive(child) then
					-- Avoid duplicates
					local found = false
					for _, t in targets do
						if t == child then
							found = true
							break
						end
					end
					if not found then
						table.insert(targets, child)
					end
				end
			end
		end
	end

	if DEBUG_TARGETING and #targets > 0 then
		print("[TargetingController] Found", #targets, "valid targets")
	end

	return targets
end

--[[
    Get the look direction for targeting
    Uses camera direction for better feel in 3rd person
]]
local function getLookDirection(): Vector3
	if Camera then
		-- Use camera's forward direction (horizontal only)
		local camLook = Camera.CFrame.LookVector
		return Vector3.new(camLook.X, 0, camLook.Z).Unit
	end

	-- Fallback to character facing
	local character = LocalPlayer.Character
	if character then
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if rootPart then
			local look = rootPart.CFrame.LookVector
			return Vector3.new(look.X, 0, look.Z).Unit
		end
	end

	return Vector3.new(0, 0, -1)
end

--[[
    Check if target is within cone angle
    Uses camera direction for 3rd person games
    If ConeAngle >= 360, skips check (target nearest regardless of direction)
]]
local function isInCone(playerPos: Vector3, targetPos: Vector3): boolean
	-- If cone is 360 degrees, always return true (target nearest enemy regardless of direction)
	if TargetConfig.ConeAngle >= 360 then
		return true
	end

	local lookDir = getLookDirection()
	local toTarget = (targetPos - playerPos)
	toTarget = Vector3.new(toTarget.X, 0, toTarget.Z) -- Horizontal only

	if toTarget.Magnitude < 0.01 then
		return true -- Target is basically on top of us
	end

	toTarget = toTarget.Unit
	local dot = lookDir:Dot(toTarget)

	-- Convert cone angle to dot product threshold
	local halfAngleRad = math.rad(TargetConfig.ConeAngle / 2)
	local threshold = math.cos(halfAngleRad)

	local inCone = dot >= threshold

	if DEBUG_TARGETING then
		local angleDeg = math.deg(math.acos(math.clamp(dot, -1, 1)))
		if not inCone then
			print(
				"[TargetingController] Target angle:",
				math.floor(angleDeg),
				"deg, threshold:",
				TargetConfig.ConeAngle / 2,
				"- OUT OF CONE"
			)
		end
	end

	return inCone
end

--[[
    Check line of sight to target (optional)
]]
local function hasLineOfSight(fromPos: Vector3, toPos: Vector3, ignoreList: { Instance }): boolean
	if not TargetConfig.RequireLineOfSight then
		return true
	end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = ignoreList

	local direction = toPos - fromPos
	local result = Workspace:Raycast(fromPos, direction, rayParams)

	-- If we hit something before reaching target, no LOS
	if result then
		local hitDistance = (result.Position - fromPos).Magnitude
		local targetDistance = direction.Magnitude
		return hitDistance >= targetDistance * 0.9 -- Allow some tolerance
	end

	return true
end

--[[
    Get the root part of a target model
]]
local function getTargetRoot(target: Model): BasePart?
	-- Try HumanoidRootPart first
	local hrp = target:FindFirstChild("HumanoidRootPart")
	if hrp then
		return hrp
	end

	-- Try Torso
	local torso = target:FindFirstChild("Torso")
	if torso then
		return torso
	end

	-- Try PrimaryPart
	if target.PrimaryPart then
		return target.PrimaryPart
	end

	-- Fallback: find any BasePart
	for _, child in target:GetChildren() do
		if child:IsA("BasePart") then
			return child
		end
	end

	return nil
end

--[[
    Find the best target
]]
local function findBestTarget(): Model?
	local character = LocalPlayer.Character
	if not character then
		if DEBUG_TARGETING then
			print("[TargetingController] No character")
		end
		return nil
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		if DEBUG_TARGETING then
			print("[TargetingController] No HumanoidRootPart")
		end
		return nil
	end

	local playerPos = rootPart.Position

	local targets = getValidTargets()
	if #targets == 0 then
		if DEBUG_TARGETING then
			print("[TargetingController] No valid targets found")
		end
		return nil
	end

	local bestTarget: Model? = nil
	local bestScore = math.huge

	for _, target in targets do
		local targetRoot = getTargetRoot(target)
		if not targetRoot then
			if DEBUG_TARGETING then
				print("[TargetingController] Target has no root part:", target.Name)
			end
			continue
		end

		local targetPos = targetRoot.Position
		local distance = (targetPos - playerPos).Magnitude

		-- Skip if out of range
		if distance > TargetConfig.MaxRange then
			if DEBUG_TARGETING then
				print("[TargetingController] Target out of range:", target.Name, distance, ">", TargetConfig.MaxRange)
			end
			continue
		end

		-- Skip if not in cone (but be lenient - use wider effective cone)
		if not isInCone(playerPos, targetPos) then
			continue
		end

		-- Skip if no line of sight
		if not hasLineOfSight(playerPos, targetPos, { character }) then
			if DEBUG_TARGETING then
				print("[TargetingController] No LOS to:", target.Name)
			end
			continue
		end

		-- Score based on distance (closer = better)
		local score = distance

		-- Bonus for targets more centered in view
		local lookDir = getLookDirection()
		local toTarget = (targetPos - playerPos).Unit
		local dot = lookDir:Dot(toTarget)
		score = score * (2 - dot) -- Targets in front get lower (better) score

		if score < bestScore then
			bestScore = score
			bestTarget = target
		end
	end

	if DEBUG_TARGETING then
		if bestTarget then
			print("[TargetingController] Best target:", bestTarget.Name, "score:", bestScore)
		else
			print("[TargetingController] No valid target in cone")
		end
	end

	return bestTarget
end

--[[
    Update target selection
]]
local function updateTarget()
	if not TargetConfig.Enabled then
		return
	end

	local newTarget = findBestTarget()

	if newTarget ~= currentTarget then
		local oldTarget = currentTarget
		currentTarget = newTarget

		if newTarget then
			TargetingController.OnTargetChanged:Fire(newTarget, oldTarget)
			if DEBUG_TARGETING then
				print("[TargetingController] TARGET CHANGED:", newTarget.Name)
			end
		elseif oldTarget then
			TargetingController.OnTargetLost:Fire()
			if DEBUG_TARGETING then
				print("[TargetingController] TARGET LOST")
			end
		end
	end
end

--[[
    Periodic update
]]
local function onHeartbeat(deltaTime: number)
	local now = os.clock()
	if now - lastUpdateTime < TargetConfig.UpdateInterval then
		return
	end
	lastUpdateTime = now

	updateTarget()

	-- Check if current target is still valid
	if currentTarget then
		if not EnemyLib:IsAlive(currentTarget) or not currentTarget.Parent then
			local oldTarget = currentTarget
			currentTarget = nil
			TargetingController.OnTargetLost:Fire()

			-- Immediately try to find new target
			updateTarget()
		end
	end
end

-- Public API --

--[[
    Get current target
]]
function TargetingController:GetTarget(): Model?
	return currentTarget
end

--[[
    Get target's root part position
]]
function TargetingController:GetTargetPosition(): Vector3?
	if not currentTarget then
		return nil
	end

	local rootPart = getTargetRoot(currentTarget)
	if not rootPart then
		return nil
	end

	return rootPart.Position
end

--[[
    Get direction to target from player
]]
function TargetingController:GetDirectionToTarget(): Vector3?
	local character = LocalPlayer.Character
	if not character or not currentTarget then
		return nil
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	local targetPos = self:GetTargetPosition()

	if not rootPart or not targetPos then
		return nil
	end

	local direction = (targetPos - rootPart.Position)
	direction = Vector3.new(direction.X, 0, direction.Z) -- Ignore Y for horizontal direction

	if direction.Magnitude > 0 then
		return direction.Unit
	end

	return nil
end

--[[
    Get distance to current target
]]
function TargetingController:GetDistanceToTarget(): number?
	local character = LocalPlayer.Character
	if not character or not currentTarget then
		return nil
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	local targetPos = self:GetTargetPosition()

	if not rootPart or not targetPos then
		return nil
	end

	return (targetPos - rootPart.Position).Magnitude
end

--[[
    Check if we have a valid target
]]
function TargetingController:HasTarget(): boolean
	return currentTarget ~= nil
end

--[[
    Force target update (call before attacks!)
]]
function TargetingController:RefreshTarget()
	lastUpdateTime = 0 -- Reset throttle
	updateTarget()
end

--[[
    Clear current target
]]
function TargetingController:ClearTarget()
	if currentTarget then
		currentTarget = nil
		TargetingController.OnTargetLost:Fire()
	end
end

--[[
    Calculate attack direction with soft lock
    Blends player forward direction with direction to target
]]
function TargetingController:GetAttackDirection(): Vector3
	local character = LocalPlayer.Character
	if not character then
		return Vector3.new(0, 0, 1)
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return Vector3.new(0, 0, 1)
	end

	-- Use camera direction as base
	local playerForward = getLookDirection()

	-- If no target or soft lock disabled, use camera forward
	if not currentTarget or TargetConfig.SoftLockStrength <= 0 then
		return playerForward
	end

	local directionToTarget = self:GetDirectionToTarget()
	if not directionToTarget then
		return playerForward
	end

	-- Blend between camera forward and target direction
	local blended = playerForward:Lerp(directionToTarget, TargetConfig.SoftLockStrength)

	if blended.Magnitude > 0 then
		return blended.Unit
	end

	return playerForward
end

--[[
    Initialize the controller
]]
function TargetingController:Init()
	print("[TargetingController] Initialized")
end

--[[
    Start the controller
]]
function TargetingController:Start()
	-- Get camera reference
	Camera = Workspace.CurrentCamera

	table.insert(connections, RunService.Heartbeat:Connect(onHeartbeat))

	-- Clear target on respawn
	table.insert(
		connections,
		LocalPlayer.CharacterAdded:Connect(function()
			currentTarget = nil
			-- Re-acquire camera
			Camera = Workspace.CurrentCamera
		end)
	)

	-- Update camera reference when it changes
	table.insert(
		connections,
		Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
			Camera = Workspace.CurrentCamera
		end)
	)

	print("[TargetingController] Started")
end

--[[
    Cleanup
]]
function TargetingController:Destroy()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	currentTarget = nil
end

return TargetingController
