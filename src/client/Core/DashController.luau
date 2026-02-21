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
local ClassConfig = require(ReplicatedStorage.Shared.Config.ClassConfig)
local EnemyLib = require(ReplicatedStorage.Shared.Lib.EnemyLib)

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
local currentDashId = 0

-- Active dash resources (for cancellation)
local activeBodyVelocity = nil
local activeHipTween = nil
local activeSlideAnimTrack = nil
local activeSlideConnection = nil
local rigBaseHipHeight = 2.0

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
    Spawn debris/dust VFX for ground slides
]]
local function spawnSlideVFX(rootPart: BasePart, dashDuration: number, dashDirection: Vector3)
	-- Spawn a trailing VFX part that follows the character during the slide.
	-- Uses a standalone Part because custom rig rootParts don't render particles reliably.
	local character = rootPart.Parent

	-- Dust cloud emitter (main effect - billowing ground dust)
	local vfxPart = Instance.new("Part")
	vfxPart.Name = "SlideVFXPart"
	vfxPart.Size = Vector3.new(1, 1, 1)
	vfxPart.Anchored = true
	vfxPart.CanCollide = false
	vfxPart.CanQuery = false
	vfxPart.CanTouch = false
	vfxPart.Transparency = 1
	vfxPart.Parent = workspace

	-- Main dust clouds
	local dust = Instance.new("ParticleEmitter")
	dust.Texture = "rbxasset://textures/particles/smoke_main.dds"
	dust.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(200, 180, 150)), -- Sandy/earthy start
		ColorSequenceKeypoint.new(1, Color3.fromRGB(160, 150, 140)), -- Faded grey end
	})
	dust.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 2),
		NumberSequenceKeypoint.new(0.3, 5),
		NumberSequenceKeypoint.new(1, 8),
	})
	dust.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(0.4, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	dust.Lifetime = NumberRange.new(0.4, 0.8)
	dust.Rate = 120
	dust.Speed = NumberRange.new(3, 10)
	dust.EmissionDirection = Enum.NormalId.Top
	dust.SpreadAngle = Vector2.new(40, 40)
	dust.Acceleration = Vector3.new(0, 4, 0) -- Gentle lift
	dust.Rotation = NumberRange.new(0, 360)
	dust.RotSpeed = NumberRange.new(-90, 90)
	dust.LightEmission = 0.1
	dust.Enabled = true
	dust.Parent = vfxPart

	-- Ground debris/sparks (small bright flecks kicked up)
	local sparks = Instance.new("ParticleEmitter")
	sparks.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	sparks.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 230, 180)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(200, 180, 140)),
	})
	sparks.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(1, 0),
	})
	sparks.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.7, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	sparks.Lifetime = NumberRange.new(0.2, 0.5)
	sparks.Rate = 60
	sparks.Speed = NumberRange.new(10, 25)
	sparks.EmissionDirection = Enum.NormalId.Top
	sparks.SpreadAngle = Vector2.new(50, 50)
	sparks.Acceleration = Vector3.new(0, -15, 0) -- Fall back down quickly
	sparks.LightEmission = 0.5
	sparks.Enabled = true
	sparks.Parent = vfxPart

	-- Initial burst
	dust:Emit(30)
	sparks:Emit(15)

	-- Follow the character at ground level during the slide
	local startTime = os.clock()
	local followConnection
	followConnection = RunService.Heartbeat:Connect(function()
		if not rootPart or not rootPart.Parent then
			followConnection:Disconnect()
			return
		end

		local elapsed = os.clock() - startTime
		if elapsed >= dashDuration then
			followConnection:Disconnect()
			dust.Enabled = false
			sparks.Enabled = false
			Debris:AddItem(vfxPart, 2)
			return
		end

		-- Raycast down from character to find actual ground position
		local rayOrigin = rootPart.Position
		local rayResult = workspace:Raycast(rayOrigin, Vector3.new(0, -20, 0), RaycastParams.new())
		local groundY = rayOrigin.Y - 4 -- Fallback
		if rayResult then
			groundY = rayResult.Position.Y + 0.3
		end

		-- Offset behind the character so dust trails from where she slid, not inside her
		local behindOffset = -dashDirection * 8
		vfxPart.CFrame = CFrame.new(rootPart.Position.X + behindOffset.X, groundY, rootPart.Position.Z + behindOffset.Z)
	end)
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

local function cleanupActiveDash(restoreHipHeight: boolean?)
	if activeSlideConnection then
		activeSlideConnection:Disconnect()
		activeSlideConnection = nil
	end

	if activeBodyVelocity and activeBodyVelocity.Parent then
		activeBodyVelocity:Destroy()
	end
	activeBodyVelocity = nil

	if activeSlideAnimTrack then
		activeSlideAnimTrack:Stop(0.2)
		activeSlideAnimTrack:Destroy()
		activeSlideAnimTrack = nil
	end

	if activeHipTween then
		activeHipTween:Cancel()
		activeHipTween = nil
	end

	-- Only restore HipHeight when the dash is actually ending, not when starting a new one
	if restoreHipHeight ~= false then
		local _, humanoid = getCharacterParts()
		if humanoid then
			TweenService:Create(humanoid, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				HipHeight = rigBaseHipHeight,
			}):Play()
		end
	end
end

--[[
    Execute the dash
]]
local function performDash()
	local character, humanoid, rootPart = getCharacterParts()
	if not character or not humanoid or not rootPart then
		return
	end

	local currentClass = LocalPlayer:GetAttribute("Class") or "Vanguard"
	local classData = ClassConfig[currentClass]

	-- Merge dash config with class overrides (specifically for the Slide)
	local currentDashConfig = {
		Cooldown = DashConfig.Cooldown,
		StaminaCost = DashConfig.StaminaCost,
		Duration = DashConfig.Duration,
		SpeedMultiplier = DashConfig.SpeedMultiplier,
		IFrameDuration = DashConfig.IFrameDuration,
		AfterimageCount = DashConfig.AfterimageCount,
	}

	-- Determine if we are doing a Slide or a Standard Dash
	local isSlide = false
	if classData and classData.DashOverride then
		-- Can we slide?
		local slideCooldownEnd = LocalPlayer:GetAttribute("DashCooldownEnd") or 0
		if tick() >= slideCooldownEnd then
			isSlide = true
			for k, v in pairs(classData.DashOverride) do
				currentDashConfig[k] = v
			end
		else
			print("[DashController] Slide on cooldown, doing normal dash. Remaining:", slideCooldownEnd - tick())
		end
	end
	print("[DashController] Class:", currentClass, "isSlide:", isSlide, "hasDashOverride:", classData and classData.DashOverride ~= nil)

	-- Check general dash spam cooldown
	local currentTime = os.clock()
	if currentTime - lastDashTime < DashConfig.Cooldown then
		return
	end

	-- Check stamina
	if currentDashConfig.StaminaCost and currentDashConfig.StaminaCost > 0 then
		if not StaminaController:HasStamina(currentDashConfig.StaminaCost) then
			StaminaController:TriggerStaminaFailure()
			return
		end

		-- Consume stamina
		if not StaminaController:UseStamina(currentDashConfig.StaminaCost) then
			return
		end
	end

	-- Start dash
	isDashing = true
	canDash = false
	lastDashTime = currentTime

	currentDashId += 1
	local thisDashId = currentDashId

	-- Clean up any accidentally lingering previous dash (skip HipHeight restore since we're starting a new one)
	cleanupActiveDash(false)

	if isSlide and currentClass == "Scrapper" then
		LocalPlayer:SetAttribute("DashCooldownEnd", tick() + currentDashConfig.Cooldown)
	end

	-- Update state
	MovementController:SetState(CharacterState.Dashing)
	DashController.OnDashStarted:Fire()

	-- Get dash direction
	local dashDirection = getDashDirection(rootPart)

	-- Rotate character to face dash direction
	-- Use MovementController's rotation system so it works properly with custom rigs (AlignOrientation + FacingOffset)
	MovementController:SetTargetRotationDuration(dashDirection, currentDashConfig.Duration + 0.1)

	-- Start i-frames
	isInvincible = true
	DashController.OnIFrameStarted:Fire()

	-- Notify server that I-frames started
	local iframeRemote = Remotes:GetEvent("IFrameStateChanged")
	if iframeRemote then
		iframeRemote:FireServer(true)
	end

	-- Animation & VFX
	print("[DashController] Spawning VFX. isSlide:", isSlide, "SlideAnimId:", currentDashConfig.SlideAnimationId)
	if isSlide and currentDashConfig.SlideAnimationId then
		-- Load and play the slide pose
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if animator then
			local anim = Instance.new("Animation")
			anim.AnimationId = currentDashConfig.SlideAnimationId
			activeSlideAnimTrack = animator:LoadAnimation(anim)
			activeSlideAnimTrack.Priority = Enum.AnimationPriority.Action
			activeSlideAnimTrack.Looped = true -- Hold the single frame pose
			activeSlideAnimTrack:Play()
		end

		-- Drop the character to the floor so they aren't floating (2.0 pushes her visibly lower than before)
		activeHipTween =
			TweenService:Create(humanoid, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				HipHeight = 2.0,
			})
		activeHipTween:Play()

		-- Trigger ground debris VFX (pass dash direction so particles trail behind correctly)
		spawnSlideVFX(rootPart, currentDashConfig.Duration, dashDirection)
	else
		-- Spawn standard afterimages for normal dash
		spawnAfterimages(character, rootPart, currentDashConfig.Duration)
	end

	-- Calculate dash velocity based on current speed
	-- Dash is a burst of speed that depreciates over time
	local baseSpeed = humanoid.WalkSpeed
	-- If standing still, assume base walk speed for dash start
	if baseSpeed < 1 then
		baseSpeed = MovementConfig.WalkSpeed
	end

	local dashSpeed = baseSpeed * (currentDashConfig.SpeedMultiplier or 3)

	-- Apply Item Modifiers (Boost distance/speed further)
	-- We interpret "DashDistance" bonus as extra speed
	local speedBonus = StatLib:GetStat(LocalPlayer, "DashDistance", 0)
	if speedBonus > 0 then
		dashSpeed = dashSpeed + (speedBonus * 2) -- Arbitrary scaling
	end

	local dashVelocity = dashDirection * dashSpeed

	-- Create BodyVelocity for smooth dash
	activeBodyVelocity = Instance.new("BodyVelocity")
	activeBodyVelocity.Name = "DashVelocity"
	activeBodyVelocity.MaxForce = Vector3.new(math.huge, 0, math.huge)
	activeBodyVelocity.Velocity = Vector3.new(dashVelocity.X, 0, dashVelocity.Z)
	activeBodyVelocity.Parent = rootPart

	-- Tween velocity down (depreciation)
	-- Slow down to normal speed by end of dash
	local endVelocity = dashDirection * MovementConfig.WalkSpeed
	TweenService:Create(
		activeBodyVelocity,
		TweenInfo.new(currentDashConfig.Duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{
			Velocity = Vector3.new(endVelocity.X, 0, endVelocity.Z),
		}
	):Play()

	-- Stop normal movement during dash
	humanoid.WalkSpeed = 0

	-- End i-frames partway through dash
	task.delay(currentDashConfig.IFrameDuration, function()
		if currentDashId ~= thisDashId then
			return
		end

		isInvincible = false
		DashController.OnIFrameEnded:Fire()

		-- Notify server that I-frames ended
		local iframeRemote = Remotes:GetEvent("IFrameStateChanged")
		if iframeRemote then
			iframeRemote:FireServer(false)
		end
	end)

	-- Scavenger's Slide Knockback logic
	print("[DashController] Knockback check: isSlide:", isSlide, "class:", currentClass, "hasSkillConfig:", classData.Skills and classData.Skills.ScavengersSlide ~= nil)
	if isSlide and currentClass == "Scrapper" and classData.Skills and classData.Skills.ScavengersSlide then
		local hitEnemies = {}
		local slideParams = OverlapParams.new()
		slideParams.FilterDescendantsInstances = { character }
		slideParams.FilterType = Enum.RaycastFilterType.Exclude

		activeSlideConnection = RunService.Heartbeat:Connect(function()
			if not rootPart or not isDashing then
				if activeSlideConnection then
					activeSlideConnection:Disconnect()
					activeSlideConnection = nil
				end
				return
			end

			local hitboxSize = classData.Skills.ScavengersSlide.HitboxSize
			local parts = workspace:GetPartBoundsInBox(rootPart.CFrame, hitboxSize, slideParams)

			for _, part in ipairs(parts) do
				local hitModel = part:FindFirstAncestorOfClass("Model")
				if hitModel and hitModel ~= character and not hitEnemies[hitModel] then
					if EnemyLib:IsAlive(hitModel) then
						hitEnemies[hitModel] = true
						print("[DashController] Slide hit enemy:", hitModel.Name)

						-- Fire remote to knockback
						local dashHitRemote = Remotes:GetEvent("RequestDashHit")
						if dashHitRemote then
							dashHitRemote:FireServer(hitModel)
						end
					end
				end
			end
		end)
	end

	-- End dash after duration
	task.delay(currentDashConfig.Duration, function()
		if currentDashId ~= thisDashId then
			return
		end

		isDashing = false
		cleanupActiveDash()

		-- Restore movement
		humanoid.WalkSpeed = MovementConfig.WalkSpeed
		MovementController:SetState(CharacterState.Idle)

		-- Preserve momentum
		MovementController:SyncVelocity()

		DashController.OnDashEnded:Fire()

		-- Allow dash again after the base global cooldown
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

--[[
    Handle jump interrupt
]]
local function onJumpPressed()
	if isDashing then
		-- Instantly cancel the dash sequence
		isDashing = false
		cleanupActiveDash()

		local _, humanoid = getCharacterParts()
		if humanoid then
			humanoid.WalkSpeed = MovementConfig.WalkSpeed
		end

		DashController.OnDashEnded:Fire()
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
	table.insert(connections, InputController.OnJumpPressed:Connect(onJumpPressed))

	-- Reset on respawn
	table.insert(
		connections,
		LocalPlayer.CharacterAdded:Connect(function(character)
			isDashing = false
			canDash = true
			isInvincible = false
			lastDashTime = 0
			currentDashId = 0

			-- Capture their default clean HipHeight on spawn, fallback to 2.0 (or 5.0 explicitly for custom rigs)
			local humanoid = character:WaitForChild("Humanoid", 3)
			if humanoid then
				local class = LocalPlayer:GetAttribute("Class")
				-- Explicitly enforce the rigid default heights just to be extra safe against loading bugs
				local expectedHeight = (class == "Scrapper") and 5.0 or humanoid.HipHeight
				rigBaseHipHeight = expectedHeight
			end
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
