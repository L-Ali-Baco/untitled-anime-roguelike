--[[
    CameraController.luau
    Third-person camera that follows the player.
    Handles both PC (mouse) and mobile (touch drag) camera rotation.
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)
local CharacterLib = require(ReplicatedStorage.Shared.Lib.CharacterLib)

local CameraController = {}
CameraController.Name = "CameraController"

-- References
local LocalPlayer = Players.LocalPlayer
local camera = workspace.CurrentCamera
local InputController = nil -- Set in Init

-- Camera state
local pitch = 0 -- Vertical rotation (looking up/down)
local yaw = 0 -- Horizontal rotation (looking left/right)
local currentDistance = CameraConfig.Distance

-- Bobbing state
local bobTime = 0

-- Smoothing state (for interpolation)
local lastCharacterPosition: Vector3? = nil
local smoothedPosition: Vector3? = nil

-- Ready state
local isReady = false

-- Connections
local connections: { RBXScriptConnection } = {}

--[[
    Get the character's root part
]]
local function getCharacterRootPart(): BasePart?
	local character = LocalPlayer.Character
	if not character then
		return nil
	end

	return CharacterLib:GetRootPart(character)
end

--[[
    Get the character's root part position with optional velocity prediction
]]
local function getCharacterPosition(deltaTime: number): Vector3?
	local rootPart = getCharacterRootPart()
	if not rootPart then
		return nil
	end

	local currentPos = rootPart.Position

	-- Initialize smoothed position if needed
	if not smoothedPosition then
		smoothedPosition = currentPos
		lastCharacterPosition = currentPos
		return currentPos
	end

	-- Smooth the target position to reduce jitter
	-- This creates a slight delay but eliminates jumpiness
	local positionSmoothing = CameraConfig.PositionSmoothing
	local alpha = 1 - math.pow(positionSmoothing, deltaTime * 60)

	smoothedPosition = smoothedPosition:Lerp(currentPos, alpha)

	lastCharacterPosition = currentPos

	return smoothedPosition
end

--[[
    Calculate camera CFrame based on pitch, yaw, and distance
]]
local function calculateCameraCFrame(targetPosition: Vector3): CFrame
	-- Create rotation from yaw (horizontal) and pitch (vertical)
	local rotation = CFrame.Angles(0, math.rad(yaw), 0) * CFrame.Angles(math.rad(pitch), 0, 0)

	-- Calculate camera position: start at target, rotate, move back
	local offset = rotation * Vector3.new(0, 0, currentDistance)
	local cameraPosition = targetPosition + Vector3.new(0, CameraConfig.Height, 0) + offset

	-- Add shoulder offset
	local shoulderOffset = rotation * CameraConfig.Offset
	cameraPosition = cameraPosition + shoulderOffset

	-- Look at the target (slightly above character center)
	local lookAtPosition = targetPosition + Vector3.new(0, CameraConfig.Height * 0.5, 0)

	return CFrame.lookAt(cameraPosition, lookAtPosition)
end

--[[
    Update camera every frame
]]
local function onRenderStepped(deltaTime: number)
	-- Don't update if not ready
	if not isReady then
		return
	end

	local characterPos = getCharacterPosition(deltaTime)
	if not characterPos then
		return
	end

	-- Safety check: If target falls into void, stop tracking to avoid camera glitching
	if characterPos.Y < -50 then
		-- Don't update camera position if target is falling into void
		return
	end

	-- Get look delta from input controller
	local lookDelta = InputController:GetLookDelta()
	local device = InputController:GetDevice()

	-- Get sensitivity based on device
	local sensitivity = CameraConfig.PC.Sensitivity
	if device == "Mobile" then
		sensitivity = CameraConfig.Mobile.Sensitivity
	elseif device == "Gamepad" then
		sensitivity = CameraConfig.Gamepad.Sensitivity
	end

	-- Apply look delta to yaw and pitch
	yaw = yaw - lookDelta.X * sensitivity
	pitch = pitch - lookDelta.Y * sensitivity

	-- Handle Y inversion
	local invertY = false
	if device == "Mobile" then
		invertY = CameraConfig.Mobile.InvertY
	elseif device == "PC" then
		invertY = CameraConfig.PC.InvertY
	elseif device == "Gamepad" then
		invertY = CameraConfig.Gamepad.InvertY
	end

	if invertY then
		pitch = pitch + lookDelta.Y * sensitivity * 2 -- Undo and invert
	end

	-- Clamp pitch to prevent flipping
	pitch = math.clamp(pitch, CameraConfig.MinPitch, CameraConfig.MaxPitch)

	-- Calculate target camera CFrame
	local targetCF = calculateCameraCFrame(characterPos)

	-- Apply procedural camera bobbing if moving
	local isMoving = false
	local rootPart = getCharacterRootPart()
	if rootPart then
		local velocity = rootPart.AssemblyLinearVelocity
		local horizontalSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
		isMoving = horizontalSpeed > 1

		if isMoving then
			-- Increase bob time based on speed (feels more authentic at different speeds)
			-- Scrapper is very fast (1.5x) so this makes it match her footfalls
			local speedScale = math.clamp(horizontalSpeed / 16, 0.5, 2.0)
			bobTime = bobTime + (deltaTime * 12 * speedScale)
		end
	end

	if isMoving then
		-- Calculate bob offsets
		-- Y bob: double frequency for walking steps (up and down twice per cycle)
		local bobY = math.sin(bobTime) * 0.015
		-- X bob: side to side sway
		local bobX = math.cos(bobTime * 0.5) * 0.008
		-- Pitch bob: slight camera tilt
		local bobPitch = math.sin(bobTime) * 0.002

		-- Apply bobbing relative to camera rotation
		local bobOffset = targetCF.RightVector * bobX + targetCF.UpVector * bobY
		targetCF = targetCF + bobOffset
		targetCF = targetCF * CFrame.Angles(bobPitch, 0, 0)
	else
		-- Quickly return to neutral when stopped
		bobTime = bobTime * (1 - deltaTime * 10)
	end

	-- Apply rotation smoothing (separate from position smoothing)
	local rotationSmoothing = CameraConfig.RotationSmoothing
	local rotAlpha = 1 - math.pow(rotationSmoothing, deltaTime * 60)

	camera.CFrame = camera.CFrame:Lerp(targetCF, rotAlpha)
end

--[[
    Initialize camera for a character
]]
local function initializeForCharacter(character: Model)
	-- Wait for humanoid first
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid then
		warn("[CameraController] Failed to find Humanoid")
		return
	end

	-- Use CharacterLib to find root part (supports custom rigs)
	-- Wait a moment for the character to fully load
	task.wait(0.1)
	local rootPart = CharacterLib:GetRootPart(character)

	if not rootPart then
		warn("[CameraController] Failed to find root part")
		return
	end

	-- Reset smoothing state
	smoothedPosition = rootPart.Position
	lastCharacterPosition = rootPart.Position

	-- Initialize yaw based on character facing direction
	local lookVector = rootPart.CFrame.LookVector
	yaw = math.deg(math.atan2(-lookVector.X, -lookVector.Z))

	-- Set initial camera position immediately (no lerp for first frame)
	local initialCFrame = calculateCameraCFrame(rootPart.Position)
	camera.CFrame = initialCFrame

	-- Mark as ready
	isReady = true

	print("[CameraController] Initialized for character, rootPart:", rootPart.Name)
end

-- Public API --

--[[
    Get the camera's forward direction (for movement relative to camera)
    Returns a flat (Y = 0) normalized vector
]]
function CameraController:GetLookDirection(): Vector3
	local lookVector = camera.CFrame.LookVector
	-- Flatten to XZ plane for movement
	local flat = Vector3.new(lookVector.X, 0, lookVector.Z)
	if flat.Magnitude > 0 then
		return flat.Unit
	end
	return Vector3.new(0, 0, -1)
end

--[[
    Get the camera's right direction (for strafing)
]]
function CameraController:GetRightDirection(): Vector3
	local rightVector = camera.CFrame.RightVector
	local flat = Vector3.new(rightVector.X, 0, rightVector.Z)
	if flat.Magnitude > 0 then
		return flat.Unit
	end
	return Vector3.new(1, 0, 0)
end

--[[
    Get current yaw (horizontal rotation in degrees)
]]
function CameraController:GetYaw(): number
	return yaw
end

--[[
    Get current pitch (vertical rotation in degrees)
]]
function CameraController:GetPitch(): number
	return pitch
end

--[[
    Set yaw directly (for cutscenes, etc.)
]]
function CameraController:SetYaw(newYaw: number)
	yaw = newYaw
end

--[[
    Set pitch directly (for cutscenes, etc.)
]]
function CameraController:SetPitch(newPitch: number)
	pitch = math.clamp(newPitch, CameraConfig.MinPitch, CameraConfig.MaxPitch)
end

--[[
    Add pitch offset (for Smart-Snap during air combos)
]]
function CameraController:AddPitchOffset(offset: number)
	pitch = math.clamp(pitch + offset, CameraConfig.MinPitch, CameraConfig.MaxPitch)
end

--[[
    Initialize the controller
]]
function CameraController:Init()
	-- Get reference to InputController (will be set after all controllers init)
	InputController = require(script.Parent.InputController)

	print("[CameraController] Initialized")
end

--[[
    Start the controller
]]
function CameraController:Start()
	-- Set camera type to scriptable (we control it)
	camera.CameraType = Enum.CameraType.Scriptable

	-- Also ensure it stays scriptable if Roblox tries to change it
	table.insert(
		connections,
		camera:GetPropertyChangedSignal("CameraType"):Connect(function()
			if camera.CameraType ~= Enum.CameraType.Scriptable then
				camera.CameraType = Enum.CameraType.Scriptable
			end
		end)
	)

	-- Connect to render loop
	table.insert(connections, RunService.RenderStepped:Connect(onRenderStepped))

	-- Handle character spawns
	table.insert(
		connections,
		LocalPlayer.CharacterAdded:Connect(function(character)
			isReady = false
			task.spawn(initializeForCharacter, character)
		end)
	)

	-- Initialize for current character if exists
	if LocalPlayer.Character then
		task.spawn(initializeForCharacter, LocalPlayer.Character)
	end

	print("[CameraController] Started")
end

--[[
    Cleanup
]]
function CameraController:Destroy()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)

	-- Restore default camera
	camera.CameraType = Enum.CameraType.Custom
	isReady = false
end

return CameraController
