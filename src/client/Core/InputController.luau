--[[
    InputController.luau
    Handles all input from mobile (joystick) and PC (keyboard/mouse).
    Provides unified interface for other controllers to read input state.
]]

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Packages.Signal)

local InputController = {}
InputController.Name = "InputController"

-- Input state
local moveDirection = Vector2.zero
local lookDelta = Vector2.zero
local inputDevice: "Mobile" | "PC" | "Gamepad" = "PC"

-- Button states
local isAttackHeld = false
local attackJustPressed = false
local dashJustPressed = false
local jumpJustPressed = false
local interactJustPressed = false

-- UI blocking state - when true, gameplay input is disabled
local isInputBlocked = false
local isMouseLocked = false

-- Key states for WASD
local keyStates = {
	W = false,
	A = false,
	S = false,
	D = false,
}

-- Signals for one-shot actions
InputController.OnAttackPressed = Signal.new() -- M1
InputController.OnSecondaryPressed = Signal.new() -- M2
InputController.OnSkill1Pressed = Signal.new() -- E
InputController.OnSkill2Pressed = Signal.new() -- R
InputController.OnDashPressed = Signal.new() -- Shift
InputController.OnJumpPressed = Signal.new() -- Space
InputController.OnInteractPressed = Signal.new() -- F
InputController.OnDeviceChanged = Signal.new()

-- Connections to clean up
local connections: { RBXScriptConnection } = {}

--[[
    Detect input device based on platform
]]
local function detectInputDevice()
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "Mobile"
	elseif UserInputService.GamepadEnabled and #UserInputService:GetConnectedGamepads() > 0 then
		return "Gamepad"
	else
		return "PC"
	end
end

--[[
    Update move direction from WASD keys
]]
local function updateKeyboardMoveDirection()
	local direction = Vector2.zero

	if keyStates.W then
		direction += Vector2.new(0, 1)
	end
	if keyStates.S then
		direction += Vector2.new(0, -1)
	end
	if keyStates.A then
		direction += Vector2.new(-1, 0)
	end
	if keyStates.D then
		direction += Vector2.new(1, 0)
	end

	-- Normalize if moving diagonally
	if direction.Magnitude > 0 then
		direction = direction.Unit
	end

	moveDirection = direction
end

--[[
    Handle keyboard input began
]]
local function onInputBegan(input: InputObject, gameProcessed: boolean)
	-- Mouse attack (M1)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		isAttackHeld = true
		attackJustPressed = true
		InputController.OnAttackPressed:Fire()
		return
	end

	-- Mouse secondary (M2)
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		InputController.OnSecondaryPressed:Fire()
		return
	end

	if gameProcessed then
		return
	end

	-- WASD Movement
	if input.KeyCode == Enum.KeyCode.W then
		keyStates.W = true
		updateKeyboardMoveDirection()
	elseif input.KeyCode == Enum.KeyCode.A then
		keyStates.A = true
		updateKeyboardMoveDirection()
	elseif input.KeyCode == Enum.KeyCode.S then
		keyStates.S = true
		updateKeyboardMoveDirection()
	elseif input.KeyCode == Enum.KeyCode.D then
		keyStates.D = true
		updateKeyboardMoveDirection()
	end

	-- Action buttons
	if input.KeyCode == Enum.KeyCode.LeftShift then
		dashJustPressed = true
		InputController.OnDashPressed:Fire()
	elseif input.KeyCode == Enum.KeyCode.Space then
		jumpJustPressed = true
		InputController.OnJumpPressed:Fire()
	elseif input.KeyCode == Enum.KeyCode.F then
		interactJustPressed = true
		InputController.OnInteractPressed:Fire()
	elseif input.KeyCode == Enum.KeyCode.E then
		InputController.OnSkill1Pressed:Fire()
	elseif input.KeyCode == Enum.KeyCode.R then
		InputController.OnSkill2Pressed:Fire()
	end
end

--[[
    Handle keyboard input ended
]]
local function onInputEnded(input: InputObject, gameProcessed: boolean)
	-- WASD Movement
	if input.KeyCode == Enum.KeyCode.W then
		keyStates.W = false
		updateKeyboardMoveDirection()
	elseif input.KeyCode == Enum.KeyCode.A then
		keyStates.A = false
		updateKeyboardMoveDirection()
	elseif input.KeyCode == Enum.KeyCode.S then
		keyStates.S = false
		updateKeyboardMoveDirection()
	elseif input.KeyCode == Enum.KeyCode.D then
		keyStates.D = false
		updateKeyboardMoveDirection()
	end

	-- Mouse attack release
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		isAttackHeld = false
	end
end

--[[
    Handle mouse movement for camera (PC only)
]]
local function onInputChanged(input: InputObject, gameProcessed: boolean)
	if input.UserInputType == Enum.UserInputType.MouseMovement then
		-- Only track mouse delta when mouse is locked
		if UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
			lookDelta = Vector2.new(input.Delta.X, input.Delta.Y)
		end
	end
end

--[[
    Clear one-shot input flags each frame
]]
local function onHeartbeat()
	attackJustPressed = false
	dashJustPressed = false
	jumpJustPressed = false
	interactJustPressed = false
	lookDelta = Vector2.zero
end

-- Public API --

--[[
    Get current input device type
]]
function InputController:GetDevice(): "Mobile" | "PC" | "Gamepad"
	return inputDevice
end

--[[
    Get current movement direction (normalized Vector2)
    X = left/right, Y = forward/backward
]]
function InputController:GetMoveDirection(): Vector2
	return moveDirection
end

--[[
    Get movement magnitude (0-1, how far joystick is pushed)
]]
function InputController:GetMoveMagnitude(): number
	return moveDirection.Magnitude
end

--[[
    Get camera look delta (mouse movement this frame)
]]
function InputController:GetLookDelta(): Vector2
	return lookDelta
end

--[[
    Check if attack is being held
]]
function InputController:IsAttackHeld(): boolean
	return isAttackHeld
end

--[[
    Set move direction (called by VirtualJoystick on mobile)
]]
function InputController:SetMoveDirection(direction: Vector2)
	moveDirection = direction
end

--[[
    Set look delta (called by touch drag on mobile)
]]
function InputController:SetLookDelta(delta: Vector2)
	lookDelta = delta
end

--[[
    Fire attack pressed (called by mobile attack button)
]]
function InputController:FireAttackPressed()
	attackJustPressed = true
	isAttackHeld = true
	InputController.OnAttackPressed:Fire()
end

--[[
    Release attack (called by mobile attack button)
]]
function InputController:ReleaseAttack()
	isAttackHeld = false
end

--[[
    Fire dash pressed (called by mobile dash button)
]]
function InputController:FireDashPressed()
	dashJustPressed = true
	InputController.OnDashPressed:Fire()
end

--[[
    Fire jump pressed (called by mobile jump button)
]]
function InputController:FireJumpPressed()
	jumpJustPressed = true
	InputController.OnJumpPressed:Fire()
end

--[[
    Fire interact pressed (called by mobile context button)
]]
function InputController:FireInteractPressed()
	interactJustPressed = true
	InputController.OnInteractPressed:Fire()
end

--[[
    Block all gameplay input (for UI screens)
]]
function InputController:BlockInput()
	isInputBlocked = true
	-- Clear any held states
	isAttackHeld = false
	moveDirection = Vector2.zero
	for key in keyStates do
		keyStates[key] = false
	end
end

--[[
    Unblock gameplay input
]]
function InputController:UnblockInput()
	isInputBlocked = false
end

--[[
    Check if input is blocked
]]
function InputController:IsInputBlocked(): boolean
	return isInputBlocked
end

--[[
    Lock mouse to center (for gameplay)
]]
function InputController:LockMouse()
	if inputDevice == "PC" then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
		isMouseLocked = true
	end
end

--[[
    Unlock mouse (for UI interaction)
]]
function InputController:UnlockMouse()
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
	isMouseLocked = false
end

--[[
    Check if mouse is locked
]]
function InputController:IsMouseLocked(): boolean
	return isMouseLocked
end

--[[
    Initialize the controller
]]
function InputController:Init()
	-- Detect initial device
	inputDevice = detectInputDevice()
	print("[InputController] Detected device:", inputDevice)
end

--[[
    Start the controller (connect events)
]]
function InputController:Start()
	-- Connect input events
	table.insert(connections, UserInputService.InputBegan:Connect(onInputBegan))
	table.insert(connections, UserInputService.InputEnded:Connect(onInputEnded))
	table.insert(connections, UserInputService.InputChanged:Connect(onInputChanged))
	table.insert(connections, RunService.Heartbeat:Connect(onHeartbeat))

	-- NOTE: Mouse is NOT locked here - it will be locked when class selection is complete
	-- This prevents the mouse from being locked while the player is trying to select a class

	-- Listen for device changes
	table.insert(
		connections,
		UserInputService.LastInputTypeChanged:Connect(function(lastInputType)
			local newDevice = detectInputDevice()
			if newDevice ~= inputDevice then
				inputDevice = newDevice
				InputController.OnDeviceChanged:Fire(newDevice)
				print("[InputController] Device changed to:", newDevice)
			end
		end)
	)

	print("[InputController] Started")
end

--[[
    Cleanup
]]
function InputController:Destroy()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)

	-- Restore mouse cursor
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
end

return InputController
