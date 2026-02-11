--[[
    MovementController.luau
    Handles character movement relative to camera direction.
    Supports both standard Humanoid movement and custom physics-based movement.
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementConfig = require(ReplicatedStorage.Shared.Config.MovementConfig)
local CharacterState = require(ReplicatedStorage.Shared.Enums.CharacterState)
local StatLib = require(ReplicatedStorage.Shared.Lib.StatLib)
local CharacterLib = require(ReplicatedStorage.Shared.Lib.CharacterLib)

local MovementController = {}
MovementController.Name = "MovementController"

-- References (set in Init)
local LocalPlayer = Players.LocalPlayer
local InputController = nil
local CameraController = nil

-- Movement state
local currentVelocity = Vector3.zero
local currentState = CharacterState.Idle
local isGrounded = true
local lastGroundedTime = 0

-- Custom rig state
local isCustomRig = false
local linearVelocityConstraint: LinearVelocity? = nil
local alignOrientationConstraint: AlignOrientation? = nil
local facingOffsetRadians = 0 -- Offset in radians to correct model facing direction
local currentYAngle = 0 -- Current Y rotation angle for smooth interpolation

-- Connections
local connections: { RBXScriptConnection } = {}

--[[
    Get the character and humanoid
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
    Check if current character is a custom rig
]]
local function checkIsCustomRig(): boolean
	local character = LocalPlayer.Character
	if not character then
		return false
	end
	return character:GetAttribute("IsCustomRig") == true
end

--[[
    Get the LinearVelocity constraint for custom movement
]]
local function getLinearVelocity(rootPart: BasePart): LinearVelocity?
	if linearVelocityConstraint and linearVelocityConstraint.Parent then
		return linearVelocityConstraint
	end
	
	linearVelocityConstraint = rootPart:FindFirstChild("MovementVelocity") :: LinearVelocity?
	return linearVelocityConstraint
end

--[[
    Get the AlignOrientation constraint for custom rotation
]]
local function getAlignOrientation(rootPart: BasePart): AlignOrientation?
	if alignOrientationConstraint and alignOrientationConstraint.Parent then
		return alignOrientationConstraint
	end
	
	alignOrientationConstraint = rootPart:FindFirstChild("RotationControl") :: AlignOrientation?
	return alignOrientationConstraint
end

--[[
    Convert 2D input direction to 3D world direction based on camera
]]
local function inputToWorldDirection(inputDir: Vector2): Vector3
	if inputDir.Magnitude < 0.01 then
		return Vector3.zero
	end

	-- Ensure CameraController is available
	if not CameraController then
		return Vector3.zero
	end

	-- Get camera directions
	local cameraLook = CameraController:GetLookDirection()
	local cameraRight = CameraController:GetRightDirection()

	-- Convert input to world space
	-- inputDir.Y is forward/backward, inputDir.X is left/right
	local worldDirection = (cameraLook * inputDir.Y) + (cameraRight * inputDir.X)

	if worldDirection.Magnitude > 0 then
		worldDirection = worldDirection.Unit
	end

	return worldDirection
end

--[[
    Check if grounded using raycast (works for custom rigs)
]]
local function checkGrounded(rootPart: BasePart, humanoid: Humanoid?): boolean
	local rayOrigin = rootPart.Position
	
	-- Calculate ray length dynamically
	local dist = 4 -- Fallback
	if humanoid then
		-- Distance from center to floor = Half Size + HipHeight
		-- Add slight margin (RaycastDistance) to ensure detection
		dist = (rootPart.Size.Y * 0.5) + humanoid.HipHeight + MovementConfig.Ground.RaycastDistance
	end
	
	local rayDirection = Vector3.new(0, -dist, 0)
	
	local raycastParams = RaycastParams.new()
	raycastParams.FilterDescendantsInstances = {LocalPlayer.Character}
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	
	local result = workspace:Raycast(rayOrigin, rayDirection, raycastParams)
	return result ~= nil
end

--[[
    Update character state based on conditions
]]
local function updateState(rootPart: BasePart, humanoid: Humanoid?, isMoving: boolean)
	-- Check if grounded using raycast (works for all rig types)
	isGrounded = checkGrounded(rootPart, humanoid)
	
	if isGrounded then
		lastGroundedTime = os.clock()
	end

	-- Determine state
	if not isGrounded then
		local yVelocity = rootPart.AssemblyLinearVelocity.Y
		if yVelocity < -1 then
			currentState = CharacterState.Falling
		else
			currentState = CharacterState.Jumping
		end
	elseif isMoving then
		currentState = CharacterState.Running
	else
		currentState = CharacterState.Idle
	end
end

--[[
    Rotate character to face movement direction
]]
local function rotateCharacter(rootPart: BasePart, direction: Vector3, deltaTime: number)
	if direction.Magnitude < 0.01 then
		return
	end

	-- Calculate target rotation (only Y-axis)
	local flatDirection = Vector3.new(direction.X, 0, direction.Z)
	if flatDirection.Magnitude < 0.01 then
		return
	end
	flatDirection = flatDirection.Unit
	
	-- Get target angle from movement direction
	local targetAngle = math.atan2(flatDirection.X, flatDirection.Z)
	
	-- Apply facing offset for custom rigs (corrects model's forward direction)
	if isCustomRig then
		targetAngle = targetAngle + facingOffsetRadians
	end
	
	-- Calculate shortest rotation from current angle
	local angleDiff = targetAngle - currentYAngle
	
	-- Normalize to -pi to pi
	while angleDiff > math.pi do angleDiff = angleDiff - 2 * math.pi end
	while angleDiff < -math.pi do angleDiff = angleDiff + 2 * math.pi end
	
	-- Smooth rotation
	local turnSpeed = MovementConfig.TurnSpeed
	local maxTurn = turnSpeed * deltaTime
	local actualTurn = math.clamp(angleDiff, -maxTurn, maxTurn)
	
	-- Update current angle
	currentYAngle = currentYAngle + actualTurn
	
	-- Normalize currentYAngle to stay within reasonable bounds
	while currentYAngle > math.pi do currentYAngle = currentYAngle - 2 * math.pi end
	while currentYAngle < -math.pi do currentYAngle = currentYAngle + 2 * math.pi end
	
	if isCustomRig then
		-- Custom rig: Update AlignOrientation constraint (physics handles the actual rotation)
		local alignOrientation = getAlignOrientation(rootPart)
		if alignOrientation then
			alignOrientation.CFrame = CFrame.Angles(0, currentYAngle, 0)
		end
	else
		-- Standard rig: use lerp for smooth rotation
		local targetCFrame = CFrame.lookAt(rootPart.Position, rootPart.Position + flatDirection)
		local alpha = math.clamp(turnSpeed * deltaTime, 0, 1)
		local currentRotation = rootPart.CFrame.Rotation
		local targetRotation = targetCFrame.Rotation
		local newRotation = currentRotation:Lerp(targetRotation, alpha)
		rootPart.CFrame = newRotation + rootPart.Position
	end
end

--[[
    Apply movement for CUSTOM rigs using LinearVelocity
]]
local function applyCustomMovement(rootPart: BasePart, direction: Vector3, deltaTime: number)
	local baseSpeed = MovementConfig.WalkSpeed
	
	-- Apply Item Modifiers
	local targetSpeed = StatLib:GetStat(LocalPlayer, "WalkSpeed", baseSpeed)
	
	-- Scale acceleration with speed
	local speedScale = math.max(1, targetSpeed / baseSpeed)
	local acceleration = MovementConfig.Acceleration * speedScale
	local deceleration = MovementConfig.Deceleration * speedScale

	-- Apply air control reduction
	if not isGrounded then
		acceleration = acceleration * MovementConfig.AirControl
		deceleration = deceleration * MovementConfig.AirControl
	end

	-- Calculate target velocity (horizontal only)
	local targetVelocity = direction * targetSpeed

	-- Accelerate or decelerate toward target
	local velocityDiff = targetVelocity - currentVelocity
	local accel = direction.Magnitude > 0 and acceleration or deceleration

	if velocityDiff.Magnitude > 0 then
		local change = velocityDiff.Unit * accel * deltaTime
		if change.Magnitude > velocityDiff.Magnitude then
			currentVelocity = targetVelocity
		else
			currentVelocity = currentVelocity + change
		end
	end

	-- Get LinearVelocity constraint
	local lv = getLinearVelocity(rootPart)
	if lv then
		-- Use PlaneVelocity (X, Z only) - gravity handles Y automatically
		lv.PlaneVelocity = Vector2.new(currentVelocity.X, currentVelocity.Z)
	else
		-- Fallback: direct velocity manipulation (preserve Y)
		local currentYVelocity = rootPart.AssemblyLinearVelocity.Y
		rootPart.AssemblyLinearVelocity = Vector3.new(currentVelocity.X, currentYVelocity, currentVelocity.Z)
	end
end

--[[
    Apply movement for STANDARD rigs using Humanoid
]]
local function applyStandardMovement(humanoid: Humanoid, rootPart: BasePart, direction: Vector3, deltaTime: number)
	local baseSpeed = MovementConfig.WalkSpeed
	
	-- Apply Item Modifiers
	local targetSpeed = StatLib:GetStat(LocalPlayer, "WalkSpeed", baseSpeed)
	
	-- Scale acceleration with speed to prevent sluggishness at high speeds
	local speedScale = math.max(1, targetSpeed / baseSpeed)
	
	local acceleration = MovementConfig.Acceleration * speedScale
	local deceleration = MovementConfig.Deceleration * speedScale

	-- Apply air control reduction
	if not isGrounded then
		acceleration = acceleration * MovementConfig.AirControl
		deceleration = deceleration * MovementConfig.AirControl
	end

	-- Calculate target velocity
	local targetVelocity = direction * targetSpeed

	-- Accelerate or decelerate toward target
	local velocityDiff = targetVelocity - currentVelocity
	local accel = direction.Magnitude > 0 and acceleration or deceleration

	if velocityDiff.Magnitude > 0 then
		local change = velocityDiff.Unit * accel * deltaTime
		if change.Magnitude > velocityDiff.Magnitude then
			currentVelocity = targetVelocity
		else
			currentVelocity = currentVelocity + change
		end
	end

	-- Apply movement using Humanoid:Move (relative to world)
	if currentVelocity.Magnitude > 0.1 then
		humanoid:Move(currentVelocity.Unit, false)
		humanoid.WalkSpeed = currentVelocity.Magnitude
	else
		humanoid:Move(Vector3.zero, false)
		currentVelocity = Vector3.zero
	end
end

--[[
    Main update loop
]]
local function onHeartbeat(deltaTime: number)
	-- Make sure InputController is ready
	if not InputController then
		return
	end

	local character, humanoid, rootPart = getCharacterParts()
	if not character or not humanoid or not rootPart then
		return
	end

	-- Don't process if dead
	if humanoid.Health <= 0 then
		currentState = CharacterState.Dead
		return
	end

	-- Get input
	local inputDir = InputController:GetMoveDirection()
	local inputMagnitude = InputController:GetMoveMagnitude()

	-- Convert to world direction
	local worldDirection = inputToWorldDirection(inputDir)

	-- Scale direction by input magnitude (for joystick sensitivity)
	worldDirection = worldDirection * inputMagnitude

	-- Update state
	local isMoving = inputMagnitude > 0.1
	updateState(rootPart, humanoid, isMoving)

	-- Apply movement based on rig type
	if isCustomRig then
		applyCustomMovement(rootPart, worldDirection, deltaTime)
	else
		applyStandardMovement(humanoid, rootPart, worldDirection, deltaTime)
	end

	-- Rotate character to face movement direction
	if isMoving and isGrounded then
		rotateCharacter(rootPart, worldDirection, deltaTime)
	end
end

-- Public API --

--[[
    Get current character state
]]
function MovementController:GetState(): string
	return currentState
end

--[[
    Check if character is grounded
]]
function MovementController:IsGrounded(): boolean
	return isGrounded
end

--[[
    Get current velocity
]]
function MovementController:GetVelocity(): Vector3
	return currentVelocity
end

--[[
    Get time since last grounded (for coyote time)
]]
function MovementController:GetTimeSinceGrounded(): number
	return os.clock() - lastGroundedTime
end

--[[
    Force a state (for dash, attack, etc. in future)
]]
function MovementController:SetState(state: string)
	currentState = state
end

--[[
    Stop all movement (for stun, etc.)
]]
function MovementController:StopMovement()
	currentVelocity = Vector3.zero
	
	local _, humanoid, rootPart = getCharacterParts()
	
	if isCustomRig and rootPart then
		local lv = getLinearVelocity(rootPart)
		if lv then
			lv.PlaneVelocity = Vector2.zero
		end
	elseif humanoid then
		humanoid:Move(Vector3.zero, false)
	end
end

--[[
    Sync internal velocity with actual physics velocity (e.g. after Dash/Jump)
]]
function MovementController:SyncVelocity()
	local _, _, rootPart = getCharacterParts()
	if rootPart then
		local vel = rootPart.AssemblyLinearVelocity
		-- Keep vertical velocity separate, only sync horizontal
		currentVelocity = Vector3.new(vel.X, 0, vel.Z)
	end
end

--[[
    Initialize the controller
]]
function MovementController:Init()
	-- Get references to other controllers
	-- Path: Features/Movement -> Features -> client -> Core
	InputController = require(script.Parent.Parent.Parent.Core.InputController)
	CameraController = require(script.Parent.Parent.Parent.Core.CameraController)

	print("[MovementController] Initialized")
end

--[[
    Start the controller
]]
function MovementController:Start()
	-- Connect to heartbeat
	table.insert(connections, RunService.Heartbeat:Connect(onHeartbeat))

	-- Setup on character spawn
	local function onCharacterAdded(character)
		currentVelocity = Vector3.zero
		currentState = CharacterState.Idle
		isGrounded = true
		linearVelocityConstraint = nil
		alignOrientationConstraint = nil
		facingOffsetRadians = 0
		currentYAngle = 0
		
		-- Wait for character to load
		task.wait(0.1)
		
		-- Check if this is a custom rig
		isCustomRig = checkIsCustomRig()
		print("[MovementController] Character loaded, isCustomRig:", isCustomRig)
		
		-- Get facing offset for custom rigs (converts degrees to radians)
		if isCustomRig then
			local offsetDegrees = character:GetAttribute("FacingOffset") or 0
			facingOffsetRadians = math.rad(offsetDegrees)
			print("[MovementController] Facing offset:", offsetDegrees, "degrees")
			
			-- Initialize currentYAngle from the character's current rotation
			local rootPart = CharacterLib:GetRootPart(character)
			if rootPart then
				local look = rootPart.CFrame.LookVector
				currentYAngle = math.atan2(look.X, look.Z)
			end
		end
		
		if not isCustomRig then
			-- Standard rig: set base walk speed
			local humanoid = character:WaitForChild("Humanoid", 5)
			if humanoid then
				humanoid.WalkSpeed = MovementConfig.WalkSpeed
			end
		end
	end
	
	-- Handle existing character
	if LocalPlayer.Character then
		task.spawn(onCharacterAdded, LocalPlayer.Character)
	end
	
	-- Handle future characters
	table.insert(connections, LocalPlayer.CharacterAdded:Connect(onCharacterAdded))

	print("[MovementController] Started")
end

--[[
    Cleanup
]]
function MovementController:Destroy()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

return MovementController
