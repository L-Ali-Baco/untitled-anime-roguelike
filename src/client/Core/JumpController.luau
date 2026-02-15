--[[
    JumpController.luau
    Handles jump mechanics including:
    - Ground jump (free)
    - Double/air jump (costs stamina)
    - Coyote time (grace period after leaving ground)
    - Jump buffering (queue jump before landing)
    - VFX integration
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Packages.Signal)
local MovementConfig = require(ReplicatedStorage.Shared.Config.MovementConfig)
local StaminaConfig = require(ReplicatedStorage.Shared.Config.StaminaConfig)
local CharacterState = require(ReplicatedStorage.Shared.Enums.CharacterState)
local StatLib = require(ReplicatedStorage.Shared.Lib.StatLib)
local CharacterLib = require(ReplicatedStorage.Shared.Lib.CharacterLib)

local JumpController = {}
JumpController.Name = "JumpController"

-- Config shorthand
local JumpConfig = MovementConfig.Jump

-- References (set in Init)
local LocalPlayer = Players.LocalPlayer
local InputController = nil
local StaminaController = nil
local MovementController = nil
local JumpEffects = nil

-- Jump state
local airJumpsRemaining = JumpConfig.AirJumpsAllowed
local lastGroundedTime = 0
local wasGrounded = true
local bufferedJumpTime = 0
local hasBufferedJump = false
local isJumping = false

-- Bonus air jumps (from upgrades/items)
local bonusAirJumps = 0

-- Signals
JumpController.OnGroundJump = Signal.new() -- Fires when ground jump occurs
JumpController.OnAirJump = Signal.new() -- Fires when air jump occurs (with jump number)
JumpController.OnLanded = Signal.new() -- Fires when landing on ground

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
    Check if player is grounded using raycast (works for custom rigs too)
]]
local function isGrounded(): boolean
	local _, _, rootPart = getCharacterParts()
	if not rootPart then
		return false
	end

	-- Use raycast for grounded check (works for all rig types)
	local rayOrigin = rootPart.Position
	local rayDirection = Vector3.new(0, -4, 0)

	local raycastParams = RaycastParams.new()
	raycastParams.FilterDescendantsInstances = { LocalPlayer.Character }
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude

	local result = workspace:Raycast(rayOrigin, rayDirection, raycastParams)
	return result ~= nil
end

--[[
    Check if within coyote time window
]]
local function isWithinCoyoteTime(): boolean
	local timeSinceGrounded = os.clock() - lastGroundedTime
	return timeSinceGrounded <= JumpConfig.CoyoteTime
end

--[[
    Check if buffered jump is still valid
]]
local function isBufferedJumpValid(): boolean
	if not hasBufferedJump then
		return false
	end
	local timeSinceBuffer = os.clock() - bufferedJumpTime
	return timeSinceBuffer <= JumpConfig.JumpBufferTime
end

--[[
    Get total allowed air jumps (base + bonus)
]]
local function getTotalAirJumps(): number
	local base = JumpConfig.AirJumpsAllowed
	return StatLib:GetStat(LocalPlayer, "AirJumps", base + bonusAirJumps)
end

--[[
    Perform a ground jump
]]
local function performGroundJump()
	local character, humanoid, rootPart = getCharacterParts()
	if not humanoid or not rootPart then
		return
	end

	-- Check if this is a custom rig
	local isCustomRig = character:GetAttribute("IsCustomRig") == true

	if isCustomRig then
		-- Custom rig: Apply jump using direct physics
		local currentVel = rootPart.AssemblyLinearVelocity
		-- Cancel any downward velocity and apply upward force
		rootPart.AssemblyLinearVelocity = Vector3.new(currentVel.X, 0, currentVel.Z)

		-- Apply upward impulse
		local jumpImpulse = Vector3.new(0, JumpConfig.Force * rootPart.AssemblyMass, 0)
		rootPart:ApplyImpulse(jumpImpulse)
	else
		-- Standard rig: Use Humanoid
		humanoid.JumpPower = JumpConfig.Force
		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	end

	isJumping = true
	hasBufferedJump = false

	-- Spawn ground dust effect
	if JumpEffects and JumpConfig.GroundDustEnabled then
		JumpEffects:SpawnGroundDust(rootPart.Position)
	end

	-- Fire signal
	JumpController.OnGroundJump:Fire()

	-- Update movement state
	MovementController:SetState(CharacterState.Jumping)
	MovementController:SyncVelocity() -- Ensure we track current momentum
end

--[[
    Perform an air jump (double jump, triple jump, etc.)
]]
local function performAirJump()
	local character, humanoid, rootPart = getCharacterParts()
	if not humanoid or not rootPart then
		return
	end

	-- Check stamina
	local staminaCost = StaminaConfig.Costs.AirJump
	if not StaminaController:HasStamina(staminaCost) then
		StaminaController:TriggerActionFailed("AirJump")
		return
	end

	-- Consume stamina
	if not StaminaController:UseStamina(staminaCost) then
		return
	end

	-- Calculate which air jump this is (for effects scaling)
	local totalAirJumps = getTotalAirJumps()
	local jumpNumber = totalAirJumps - airJumpsRemaining + 1

	-- Consume air jump
	airJumpsRemaining = airJumpsRemaining - 1

	-- Cancel current vertical velocity and apply new jump force
	-- We need to use AssemblyLinearVelocity to override existing velocity
	local currentVel = rootPart.AssemblyLinearVelocity
	rootPart.AssemblyLinearVelocity = Vector3.new(currentVel.X, 0, currentVel.Z)

	-- Apply upward impulse
	local jumpImpulse = Vector3.new(0, JumpConfig.AirJumpForce * rootPart.AssemblyMass, 0)
	rootPart:ApplyImpulse(jumpImpulse)

	isJumping = true

	-- Spawn air burst effect
	if JumpEffects and JumpConfig.AirBurstEnabled then
		JumpEffects:SpawnAirBurst(rootPart.Position, jumpNumber)
	end

	-- Fire signal with jump number
	JumpController.OnAirJump:Fire(jumpNumber)

	-- Update movement state
	MovementController:SetState(CharacterState.Jumping)
	MovementController:SyncVelocity() -- Carry momentum from impulse
end

--[[
    Handle jump input
]]
local function onJumpPressed()
	local grounded = isGrounded()

	-- Ground jump (including coyote time)
	if grounded or isWithinCoyoteTime() then
		performGroundJump()
		return
	end

	-- Air jump
	if airJumpsRemaining > 0 then
		performAirJump()
		return
	end

	-- Buffer the jump for when we land
	hasBufferedJump = true
	bufferedJumpTime = os.clock()
end

--[[
    Update loop - handles grounded state and buffered jumps
]]
local function onHeartbeat(deltaTime: number)
	local character, humanoid, rootPart = getCharacterParts()
	if not character or not humanoid or not rootPart then
		return
	end

	local grounded = isGrounded()

	-- Track grounded time for coyote time
	if grounded then
		lastGroundedTime = os.clock()
	end

	-- Detect landing
	if grounded and not wasGrounded then
		-- Just landed
		airJumpsRemaining = getTotalAirJumps()
		isJumping = false

		JumpController.OnLanded:Fire()

		-- Check for buffered jump
		if isBufferedJumpValid() then
			-- Small delay to ensure we're fully grounded
			task.defer(function()
				if isGrounded() then
					performGroundJump()
				end
			end)
		end
	end

	-- Detect leaving ground (for coyote time tracking)
	if not grounded and wasGrounded and not isJumping then
		-- Walked off ledge (not jumped), coyote time starts
		-- Air jumps are still available
	end

	wasGrounded = grounded
end

-- Public API --

--[[
    Get remaining air jumps
]]
function JumpController:GetAirJumpsRemaining(): number
	return airJumpsRemaining
end

--[[
    Get total air jumps allowed (base + bonus)
]]
function JumpController:GetTotalAirJumps(): number
	return getTotalAirJumps()
end

--[[
    Check if can perform any jump
]]
function JumpController:CanJump(): boolean
	if isGrounded() or isWithinCoyoteTime() then
		return true
	end
	return airJumpsRemaining > 0 and StaminaController:HasStamina(StaminaConfig.Costs.AirJump)
end

--[[
    Add bonus air jumps (from items/upgrades)
]]
function JumpController:AddBonusAirJumps(count: number)
	bonusAirJumps = bonusAirJumps + count
	-- Also add to current remaining if we're grounded
	if isGrounded() then
		airJumpsRemaining = getTotalAirJumps()
	end
end

--[[
    Remove bonus air jumps
]]
function JumpController:RemoveBonusAirJumps(count: number)
	bonusAirJumps = math.max(0, bonusAirJumps - count)
end

--[[
    Reset bonus air jumps (for run end, etc.)
]]
function JumpController:ResetBonusAirJumps()
	bonusAirJumps = 0
end

--[[
    Check if currently in a jump
]]
function JumpController:IsJumping(): boolean
	return isJumping
end

--[[
    Force reset air jumps (for special abilities, etc.)
]]
function JumpController:ResetAirJumps()
	airJumpsRemaining = getTotalAirJumps()
end

--[[
    Initialize the controller
]]
function JumpController:Init()
	-- Get references to other controllers
	InputController = require(script.Parent.InputController)
	StaminaController = require(script.Parent.StaminaController)
	MovementController = require(script.Parent.Parent.Features.Movement.MovementController)

	-- Try to load jump effects (may not exist yet)
	local success, result = pcall(function()
		return require(script.Parent.Parent.VFX.JumpEffects)
	end)
	if success then
		JumpEffects = result
	else
		warn("[JumpController] JumpEffects not found, VFX disabled")
	end

	print("[JumpController] Initialized")
end

--[[
    Start the controller
]]
function JumpController:Start()
	-- Listen for jump input
	table.insert(connections, InputController.OnJumpPressed:Connect(onJumpPressed))

	-- Update loop
	table.insert(connections, RunService.Heartbeat:Connect(onHeartbeat))

	-- Reset on respawn
	table.insert(
		connections,
		LocalPlayer.CharacterAdded:Connect(function(character)
			airJumpsRemaining = getTotalAirJumps()
			wasGrounded = true
			isJumping = false
			hasBufferedJump = false
			lastGroundedTime = os.clock()

			-- Wait for humanoid and set jump power
			local humanoid = character:WaitForChild("Humanoid", 5)
			if humanoid then
				humanoid.JumpPower = JumpConfig.Force
				-- Disable default jump so we control it
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
			end
		end)
	)

	print("[JumpController] Started")
end

--[[
    Cleanup
]]
function JumpController:Destroy()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

return JumpController
