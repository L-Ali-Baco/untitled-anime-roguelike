--[[
    ClassController.luau
    Manages the player's selected class.
    Provides attack data based on class type (Melee/Ranged).
    Handles custom character animations for custom rigs.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Packages.Signal)
local ClassConfig = require(ReplicatedStorage.Shared.Config.ClassConfig)
local CombatConfig = require(ReplicatedStorage.Shared.Config.CombatConfig)

local ClassController = {}
ClassController.Name = "ClassController"

-- References
local LocalPlayer = Players.LocalPlayer

-- State
local currentClass: string? = nil
local classData: any = nil

-- Animation state for custom rigs
local currentIdleTrack: AnimationTrack? = nil
local currentRunTrack: AnimationTrack? = nil
local currentRunShootTrack: AnimationTrack? = nil
local lastShootTime = 0
local animationConnections: { RBXScriptConnection } = {}

-- Signals
ClassController.OnClassSelected = Signal.new() -- Fires (className, classData)
ClassController.OnClassCleared = Signal.new() -- Fires when class is reset

-- Remotes (set in Start)
local Remotes = nil

--[[
    Select a class
]]
function ClassController:SelectClass(className: string): boolean
	-- Validate class exists
	local data = ClassConfig[className]
	if not data then
		warn("[ClassController] Invalid class:", className)
		return false
	end

	currentClass = className
	classData = data

	-- Set attribute for immediate UI feedback (like EnemyHealthBar range)
	LocalPlayer:SetAttribute("Class", className)

	print("[ClassController] Selected class:", className)

	-- Notify server
	if Remotes and Remotes.SelectClass then
		Remotes.SelectClass:FireServer(className)
	end

	-- Fire signal
	ClassController.OnClassSelected:Fire(className, data)

	return true
end

--[[
    Clear class selection (on death/respawn)
]]
function ClassController:ClearClass()
	if currentClass then
		currentClass = nil
		classData = nil
		ClassController.OnClassCleared:Fire()
		print("[ClassController] Class cleared")
	end
end

--[[
    Get currently selected class name
]]
function ClassController:GetCurrentClass(): string?
	return currentClass
end

--[[
    Get current class data table
]]
function ClassController:GetClassData(): any
	return classData
end

--[[
    Check if a class is selected
]]
function ClassController:IsClassSelected(): boolean
	return currentClass ~= nil
end

--[[
    Get attack type for current class ("Melee" or "Ranged")
]]
function ClassController:GetAttackType(): string
	if classData then
		return classData.AttackType or "Melee"
	end
	return "Melee" -- Default
end

--[[
    Get melee attack data for a combo hit (for Warrior)
    Falls back to CombatConfig if class doesn't override
]]
function ClassController:GetMeleeAttackData(comboHit: number): any
	-- Check if class has custom attacks
	if classData and classData.Attacks then
		local attack = classData.Attacks[comboHit]
		if attack then
			return attack
		end
	end

	-- Fall back to default CombatConfig
	return CombatConfig.Attacks[comboHit]
end

--[[
    Get ranged attack config (for Scrapper)
]]
function ClassController:GetRangedAttackData(): any
	if classData and classData.RangedAttack then
		return classData.RangedAttack
	end
	return nil
end

--[[
    Clean up animation state
]]
local function cleanupAnimations()
	-- Stop current idle track
	if currentIdleTrack then
		currentIdleTrack:Stop(0.2)
		currentIdleTrack:Destroy()
		currentIdleTrack = nil
	end

	-- Stop current run track
	if currentRunTrack then
		currentRunTrack:Stop(0.2)
		currentRunTrack:Destroy()
		currentRunTrack = nil
	end
	if currentRunShootTrack then
		currentRunShootTrack:Stop(0.2)
		currentRunShootTrack:Destroy()
		currentRunShootTrack = nil
	end

	-- Disconnect animation connections
	for _, connection in animationConnections do
		connection:Disconnect()
	end
	animationConnections = {}
end

--[[
    Set up animations for custom character rigs
]]
local function setupCustomCharacterAnimations(character: Model)
	-- Clean up any existing animations
	cleanupAnimations()

	-- Check if this is a custom rig
	if not character:GetAttribute("IsCustomRig") then
		return
	end

	print("[ClassController] Setting up animations for custom rig")

	-- Get animation IDs from config or attributes
	local idleAnimationId = character:GetAttribute("IdleAnimationId")
	if not idleAnimationId and classData and classData.IdleAnimationId then
		idleAnimationId = classData.IdleAnimationId
	end

	local runAnimationId = character:GetAttribute("RunAnimationId")
	if not runAnimationId and classData and classData.RunAnimationId then
		runAnimationId = classData.RunAnimationId
	end

	local runShootAnimationId = character:GetAttribute("RunShootAnimationId")
	if not runShootAnimationId and classData and classData.RunShootAnimationId then
		runShootAnimationId = classData.RunShootAnimationId
	end

	-- Wait for humanoid
	local humanoid = character:WaitForChild("Humanoid", 5)
	if not humanoid then
		warn("[ClassController] No Humanoid found in custom rig")
		return
	end

	local rootPart = character:WaitForChild("HumanoidRootPart", 5)

	-- Get or create Animator
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	-- DEBUG: Print rig type info
	print("[ClassController] Humanoid RigType:", humanoid.RigType)
	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		warn("[ClassController] WARNING: Custom character is detected as R6! R15 animations will NOT work.")
	end

	-- Load Idle Animation
	if idleAnimationId then
		local idleAnimation = Instance.new("Animation")
		idleAnimation.AnimationId = idleAnimationId

		local success, track = pcall(function()
			return animator:LoadAnimation(idleAnimation)
		end)

		if success and track then
			track.Priority = Enum.AnimationPriority.Idle
			track.Looped = true
			currentIdleTrack = track
		end
		idleAnimation:Destroy()
	end

	-- Load Run Animation
	if runAnimationId then
		local runAnimation = Instance.new("Animation")
		runAnimation.AnimationId = runAnimationId

		local success, track = pcall(function()
			return animator:LoadAnimation(runAnimation)
		end)

		if success and track then
			track.Priority = Enum.AnimationPriority.Movement
			track.Looped = true
			currentRunTrack = track
		end
		runAnimation:Destroy()
	end

	-- Load Run-Shoot Animation
	if runShootAnimationId then
		local runShootAnimation = Instance.new("Animation")
		runShootAnimation.AnimationId = runShootAnimationId

		local success, track = pcall(function()
			return animator:LoadAnimation(runShootAnimation)
		end)

		if success and track then
			track.Priority = Enum.AnimationPriority.Movement
			track.Looped = true
			currentRunShootTrack = track
		end
		runShootAnimation:Destroy()
	end

	-- Listen for shots to trigger RunShoot
	local CombatController = require(script.Parent.Parent.Parent.Core.CombatController)
	local shootConnection = CombatController.OnRangedFired:Connect(function()
		lastShootTime = os.clock()
	end)
	table.insert(animationConnections, shootConnection)

	-- Handle animation state switching
	local function updateAnimations()
		if not rootPart then
			return
		end

		-- Calculate horizontal speed (ignore vertical)
		local velocity = rootPart.AssemblyLinearVelocity
		local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude

		-- Threshold for "moving"
		local isMoving = speed > 0.5

		local timeSinceShot = os.clock() - lastShootTime
		local isShooting = timeSinceShot < 0.3 -- Keep animation playing shortly after firing

		if isMoving then
			local playbackSpeed = math.max(0.5, speed / 16)

			if isShooting and currentRunShootTrack then
				-- Play RunShoot, Stop Run, Stop Idle
				if not currentRunShootTrack.IsPlaying then
					currentRunShootTrack:Play(0.1)
				end
				currentRunShootTrack:AdjustSpeed(playbackSpeed)

				if currentRunTrack and currentRunTrack.IsPlaying then
					currentRunTrack:Stop(0.1)
				end
			else
				-- Play Run, Stop RunShoot, Stop Idle
				if currentRunTrack then
					if not currentRunTrack.IsPlaying then
						currentRunTrack:Play(0.2)
					end
					currentRunTrack:AdjustSpeed(playbackSpeed)
				end

				if currentRunShootTrack and currentRunShootTrack.IsPlaying then
					currentRunShootTrack:Stop(0.2)
				end
			end

			if currentIdleTrack and currentIdleTrack.IsPlaying then
				currentIdleTrack:Stop(0.2)
			end
		else
			-- Play Idle, Stop Run, Stop RunShoot
			if currentIdleTrack and not currentIdleTrack.IsPlaying then
				currentIdleTrack:Play(0.2)
			end
			if currentRunTrack and currentRunTrack.IsPlaying then
				currentRunTrack:Stop(0.2)
			end
			if currentRunShootTrack and currentRunShootTrack.IsPlaying then
				currentRunShootTrack:Stop(0.2)
			end
		end
	end

	-- Connect update loop
	local runServiceConnection = game:GetService("RunService").Heartbeat:Connect(updateAnimations)
	table.insert(animationConnections, runServiceConnection)

	-- Handle death
	local stateConnection = humanoid.StateChanged:Connect(function(_, newState)
		if newState == Enum.HumanoidStateType.Dead then
			cleanupAnimations()
		end
	end)
	table.insert(animationConnections, stateConnection)
end

--[[
    Get class color
]]
function ClassController:GetClassColor(): Color3
	if classData then
		return classData.Color or Color3.fromRGB(255, 255, 255)
	end
	return Color3.fromRGB(255, 255, 255)
end

--[[
    Get move speed multiplier for current class
]]
function ClassController:GetMoveSpeedMultiplier(): number
	if classData then
		return classData.MoveSpeedMultiplier or 1.0
	end
	return 1.0
end

--[[
    Get all available classes for UI
]]
function ClassController:GetAvailableClasses(): { string }
	return ClassConfig.ClassOrder or { "Warrior", "Scrapper" }
end

--[[
    Get class info for UI display
]]
function ClassController:GetClassInfo(className: string): any
	return ClassConfig[className]
end

--[[
    Initialize the controller
]]
function ClassController:Init()
	print("[ClassController] Initialized")
end

--[[
    Start the controller
]]
function ClassController:Start()
	-- Get remotes
	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes", 5)
	if remotesFolder then
		Remotes = {
			SelectClass = remotesFolder:FindFirstChild("SelectClass"),
			ClassSelected = remotesFolder:FindFirstChild("ClassSelected"),
		}

		-- Listen for server confirmation
		if Remotes.ClassSelected then
			Remotes.ClassSelected.OnClientEvent:Connect(function(className)
				print("[ClassController] Server confirmed class:", className)
			end)
		end
	end

	-- Handle character added - set up custom animations if needed
	local function onCharacterAdded(character)
		-- Wait a moment for attributes to be set by server
		task.wait(0.2)

		-- Check if this is a custom rig and set up animations
		if character:GetAttribute("IsCustomRig") then
			setupCustomCharacterAnimations(character)
		end
	end

	-- Connect to current character if exists
	if LocalPlayer.Character then
		task.spawn(function()
			onCharacterAdded(LocalPlayer.Character)
		end)
	end

	-- Connect to future characters
	LocalPlayer.CharacterAdded:Connect(onCharacterAdded)

	-- Clean up animations when character is removed
	LocalPlayer.CharacterRemoving:Connect(function()
		cleanupAnimations()
	end)

	print("[ClassController] Started")
end

--[[
    Cleanup
]]
function ClassController:Destroy()
	cleanupAnimations()
	currentClass = nil
	classData = nil
end

return ClassController
