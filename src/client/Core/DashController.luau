--[[
    DashController.luau
    Handles dash ability with:
    - Stamina consumption
    - Invincibility frames (i-frames)
    - Afterimage visual effect
    - Cooldown management
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local Signal = require(ReplicatedStorage.Packages.Signal)
local MovementConfig = require(ReplicatedStorage.Shared.Config.MovementConfig)
local CharacterState = require(ReplicatedStorage.Shared.Enums.CharacterState)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local StatLib = require(ReplicatedStorage.Shared.Lib.StatLib)
local CharacterLib = require(ReplicatedStorage.Shared.Lib.CharacterLib)

local DashController = {}
DashController.Name = "DashController"

-- Config shorthand
local DashConfig = MovementConfig.Dash

-- References (set in Init)
local LocalPlayer = Players.LocalPlayer
local InputController = nil
local StaminaController = nil
local MovementController = nil
local CameraController = nil

-- Dash state
local isDashing = false
local canDash = true
local lastDashTime = 0
local isInvincible = false

-- Signals
DashController.OnDashStarted = Signal.new() -- Fires when dash begins
DashController.OnDashEnded = Signal.new() -- Fires when dash ends
DashController.OnIFrameStarted = Signal.new() -- Fires when i-frames begin
DashController.OnIFrameEnded = Signal.new() -- Fires when i-frames end

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
    Create a single afterimage ghost effect
]]
local function createAfterimage(character: Model, rootPart: BasePart, transparency: number)
	-- Create ghost model
	local ghost = Instance.new("Model")
	ghost.Name = "DashAfterimage"

	-- Clone visible parts
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
			local clone = part:Clone()

			-- Remove scripts, welds, etc.
			for _, child in clone:GetDescendants() do
				if
					not child:IsA("SpecialMesh")
					and not child:IsA("FileMesh")
					and not child:IsA("SurfaceAppearance")
				then
					pcall(function()
						child:Destroy()
					end)
				end
			end

			-- Make it ghostly
			clone.Anchored = true
			clone.CanCollide = false
			clone.CanQuery = false
			clone.CanTouch = false
			clone.CastShadow = false
			clone.Transparency = transparency

			-- Apply ghost color (cyan/blue tint for anime effect)
			clone.Color = Color3.fromRGB(100, 200, 255)
			clone.Material = Enum.Material.Neon

			clone.Parent = ghost
		end
	end

	-- Position ghost at current character position
	ghost:PivotTo(character:GetPivot())
	ghost.Parent = workspace

	-- Fade out the ghost
	local fadeDuration = 0.3
	local startTime = os.clock()

	local fadeConnection
	fadeConnection = RunService.Heartbeat:Connect(function()
		local elapsed = os.clock() - startTime
		local alpha = elapsed / fadeDuration

		if alpha >= 1 then
			fadeConnection:Disconnect()
			ghost:Destroy()
			return
		end

		-- Fade transparency
		local newTransparency = transparency + (1 - transparency) * alpha
		for _, part in ghost:GetDescendants() do
			if part:IsA("BasePart") then
				part.Transparency = newTransparency
			end
		end
	end)

	-- Safety cleanup
	Debris:AddItem(ghost, fadeDuration + 0.1)
end

--[[
    Spawn multiple afterimages during dash
]]
local function spawnAfterimages(character: Model, rootPart: BasePart, dashDuration: number)
	local count = DashConfig.AfterimageCount
	local interval = dashDuration / (count + 1)

	for i = 1, count do
		task.delay(interval * i, function()
			if isDashing then
				local baseTransparency = 0.3 + (i / count) * 0.4 -- 0.3 to 0.7
				createAfterimage(character, rootPart, baseTransparency)
			end
		end)
	end
end

--[[
    Calculate dash direction based on input or facing direction
]]
local function getDashDirection(rootPart: BasePart): Vector3
	-- Get input direction
	local inputDir = InputController:GetMoveDirection()

	if inputDir.Magnitude > 0.1 then
		-- Dash in input direction (relative to camera)
		local cameraLook = CameraController:GetLookDirection()
		local cameraRight = CameraController:GetRightDirection()

		local worldDirection = (cameraLook * inputDir.Y) + (cameraRight * inputDir.X)
		if worldDirection.Magnitude > 0 then
			return worldDirection.Unit
		end
	end

	-- Default to facing direction
	return rootPart.CFrame.LookVector
end

--[[
    Execute the dash
]]
local function performDash()
	local character, humanoid, rootPart = getCharacterParts()
	if not character or not humanoid or not rootPart then
		return
	end

	-- Check cooldown
	local currentTime = os.clock()
	if currentTime - lastDashTime < DashConfig.Cooldown then
		return
	end

	-- Check stamina
	if not StaminaController:HasStamina(DashConfig.StaminaCost) then
		-- TODO: Play "no stamina" feedback sound/effect
		return
	end

	-- Consume stamina
	if not StaminaController:UseStamina(DashConfig.StaminaCost) then
		return
	end

	-- Start dash
	isDashing = true
	canDash = false
	lastDashTime = currentTime

	-- Update state
	MovementController:SetState(CharacterState.Dashing)
	DashController.OnDashStarted:Fire()

	-- Get dash direction
	local dashDirection = getDashDirection(rootPart)

	-- Rotate character to face dash direction
	local targetCFrame = CFrame.lookAt(rootPart.Position, rootPart.Position + dashDirection)
	rootPart.CFrame = CFrame.new(rootPart.Position) * targetCFrame.Rotation

	-- Start i-frames
	isInvincible = true
	DashController.OnIFrameStarted:Fire()

	-- Notify server that I-frames started
	local iframeRemote = Remotes:GetEvent("IFrameStateChanged")
	if iframeRemote then
		iframeRemote:FireServer(true)
	end

	-- Spawn afterimages
	spawnAfterimages(character, rootPart, DashConfig.Duration)

	-- Calculate dash velocity based on current speed
	-- Dash is a burst of speed that depreciates over time
	local baseSpeed = humanoid.WalkSpeed
	-- If standing still, assume base walk speed for dash start
	if baseSpeed < 1 then baseSpeed = MovementConfig.WalkSpeed end
	
	local dashSpeed = baseSpeed * (DashConfig.SpeedMultiplier or 3)
	
	-- Apply Item Modifiers (Boost distance/speed further)
	-- We interpret "DashDistance" bonus as extra speed
	local speedBonus = StatLib:GetStat(LocalPlayer, "DashDistance", 0)
	if speedBonus > 0 then
		dashSpeed = dashSpeed + (speedBonus * 2) -- Arbitrary scaling
	end
	
	local dashVelocity = dashDirection * dashSpeed

	-- Create BodyVelocity for smooth dash
	local bodyVelocity = Instance.new("BodyVelocity")
	bodyVelocity.Name = "DashVelocity"
	bodyVelocity.MaxForce = Vector3.new(math.huge, 0, math.huge)
	bodyVelocity.Velocity = Vector3.new(dashVelocity.X, 0, dashVelocity.Z)
	bodyVelocity.Parent = rootPart

	-- Tween velocity down (depreciation)
	-- Slow down to normal speed by end of dash
	local endVelocity = dashDirection * MovementConfig.WalkSpeed
	TweenService:Create(bodyVelocity, TweenInfo.new(DashConfig.Duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Velocity = Vector3.new(endVelocity.X, 0, endVelocity.Z)
	}):Play()

	-- Stop normal movement during dash
	humanoid.WalkSpeed = 0

	-- End i-frames partway through dash
	task.delay(DashConfig.IFrameDuration, function()
		isInvincible = false
		DashController.OnIFrameEnded:Fire()

		-- Notify server that I-frames ended
		local iframeRemote = Remotes:GetEvent("IFrameStateChanged")
		if iframeRemote then
			iframeRemote:FireServer(false)
		end
	end)

	-- End dash after duration
	task.delay(DashConfig.Duration, function()
		isDashing = false

		-- Remove body velocity
		if bodyVelocity and bodyVelocity.Parent then
			bodyVelocity:Destroy()
		end

		-- Restore movement
		humanoid.WalkSpeed = MovementConfig.WalkSpeed
		MovementController:SetState(CharacterState.Idle)
		
		-- Preserve momentum
		MovementController:SyncVelocity()

		DashController.OnDashEnded:Fire()

		-- Allow dash again after cooldown
		task.delay(DashConfig.Cooldown, function()
			canDash = true
		end)
	end)
end

--[[
    Handle dash input
]]
local function onDashPressed()
	if not isDashing and canDash then
		performDash()
	end
end

-- Public API --

--[[
    Check if currently dashing
]]
function DashController:IsDashing(): boolean
	return isDashing
end

--[[
    Check if can dash (not on cooldown)
]]
function DashController:CanDash(): boolean
	return canDash and not isDashing
end

--[[
    Check if currently invincible (i-frames)
]]
function DashController:IsInvincible(): boolean
	return isInvincible
end

--[[
    Get dash cooldown remaining
]]
function DashController:GetCooldownRemaining(): number
	local elapsed = os.clock() - lastDashTime
	local remaining = DashConfig.Cooldown - elapsed
	return math.max(0, remaining)
end

--[[
    Force dash (for items/abilities that grant free dash)
]]
function DashController:ForceDash()
	if not isDashing then
		performDash()
	end
end

--[[
    Initialize the controller
]]
function DashController:Init()
	-- Get references to other controllers
	InputController = require(script.Parent.InputController)
	StaminaController = require(script.Parent.StaminaController)
	MovementController = require(script.Parent.Parent.Features.Movement.MovementController)
	CameraController = require(script.Parent.CameraController)

	print("[DashController] Initialized")
end

--[[
    Start the controller
]]
function DashController:Start()
	-- Listen for dash input
	table.insert(connections, InputController.OnDashPressed:Connect(onDashPressed))

	-- Reset on respawn
	table.insert(
		connections,
		LocalPlayer.CharacterAdded:Connect(function()
			isDashing = false
			canDash = true
			isInvincible = false
			lastDashTime = 0
		end)
	)

	print("[DashController] Started")
end

--[[
    Cleanup
]]
function DashController:Destroy()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

return DashController
