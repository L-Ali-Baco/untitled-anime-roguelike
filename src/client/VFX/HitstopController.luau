--[[
    HitstopController.luau
    Creates freeze-frame effect when attacks land.
    
    IMPORTANT: Only freezes the LOCAL PLAYER character during hitstop.
    Enemies are NOT frozen here because their physics are server-authoritative.
    Freezing enemies client-side causes teleportation when they unsync with server.
    Enemy hitstun visual feedback is handled by EnemyVFXController (Highlights only).
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local CombatConfig = require(ReplicatedStorage.Shared.Config.CombatConfig)

local HitstopController = {}
HitstopController.Name = "HitstopController"

-- Config shorthand
local HitstopConfig = CombatConfig.Hitstop

-- State
local isInHitstop = false
local frozenObjects: { [BasePart]: { Position: Vector3, Anchored: boolean } } = {}
local frozenAnimations: { [AnimationTrack]: number } = {} -- Track -> original speed

-- References
local LocalPlayer = Players.LocalPlayer

--[[
    Check if a model is an enemy (server-controlled, should not be frozen)
]]
local function isEnemyModel(model: Model): boolean
	if not model then
		return false
	end

	-- Check for Enemy tag
	if CollectionService:HasTag(model, "Enemy") then
		return true
	end

	-- Check for common enemy names
	local enemyNames = { "Minion", "Brute", "Shooter" }
	for _, name in enemyNames do
		if model.Name == name then
			return true
		end
	end

	-- Check if it's NOT the local player's character (anything else might be enemy)
	if model ~= LocalPlayer.Character then
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid then
			-- Has humanoid but isn't our character - likely an enemy/NPC
			-- Be conservative: check if it has the targeting tag
			if CollectionService:HasTag(model, CombatConfig.Targeting.TargetTag) then
				return true
			end
		end
	end

	return false
end

--[[
    Freeze a single part by anchoring it
    NOTE: Should only be called for player character parts, not enemies
]]
local function freezePart(part: BasePart)
	if frozenObjects[part] then
		return -- Already frozen
	end

	frozenObjects[part] = {
		Position = part.Position,
		Anchored = part.Anchored,
		Velocity = part.AssemblyLinearVelocity,
		AngularVelocity = part.AssemblyAngularVelocity,
	}

	part.Anchored = true
	part.AssemblyLinearVelocity = Vector3.zero
	part.AssemblyAngularVelocity = Vector3.zero
end

--[[
    Unfreeze a single part
]]
local function unfreezePart(part: BasePart)
	local data = frozenObjects[part]
	if not data then
		return
	end

	part.Anchored = data.Anchored

	-- Restore velocities for player character
	if not data.Anchored then
		part.AssemblyLinearVelocity = data.Velocity
		part.AssemblyAngularVelocity = data.AngularVelocity
	end

	frozenObjects[part] = nil
end

--[[
    Freeze a character model
    IMPORTANT: Only freezes the LOCAL PLAYER, not enemies
]]
local function freezeCharacter(character: Model)
	if not character then
		return
	end

	-- CRITICAL: Skip enemies - their physics are server-controlled
	-- Freezing them client-side causes desync and teleportation
	if isEnemyModel(character) then
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if rootPart then
		freezePart(rootPart)
	end

	-- Freeze all animations
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if animator then
			for _, track in animator:GetPlayingAnimationTracks() do
				if not frozenAnimations[track] then
					frozenAnimations[track] = track.Speed
					track:AdjustSpeed(0)
				end
			end
		end
	end
end

--[[
    Unfreeze a character model
]]
local function unfreezeCharacter(character: Model)
	if not character then
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if rootPart then
		unfreezePart(rootPart)
	end

	-- Restore animation speeds
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if animator then
			for _, track in animator:GetPlayingAnimationTracks() do
				local originalSpeed = frozenAnimations[track]
				if originalSpeed then
					track:AdjustSpeed(originalSpeed)
					frozenAnimations[track] = nil
				end
			end
		end
	end
end

--[[
    Unfreeze all frozen objects
]]
local function unfreezeAll()
	-- Unfreeze all parts
	for part, _ in pairs(frozenObjects) do
		if part and part.Parent then
			unfreezePart(part)
		end
	end
	table.clear(frozenObjects)

	-- Restore all animation speeds
	for track, speed in pairs(frozenAnimations) do
		if track then
			pcall(function()
				track:AdjustSpeed(speed)
			end)
		end
	end
	table.clear(frozenAnimations)

	isInHitstop = false
end

-- Public API --

--[[
    Check if currently in hitstop
]]
function HitstopController:IsInHitstop(): boolean
	return isInHitstop
end

--[[
    Apply hitstop effect
    @param duration - How long to freeze (clamped to config limits)
    @param hitTargets - Array of character models that were hit
]]
function HitstopController:ApplyHitstop(duration: number, hitTargets: { Model }?)
	if not HitstopConfig.Enabled then
		return
	end

	-- Already in hitstop, extend it
	if isInHitstop then
		unfreezeAll()
	end

	-- Clamp duration
	duration = math.clamp(duration, HitstopConfig.MinDuration, HitstopConfig.MaxDuration)

	isInHitstop = true

	-- Freeze player
	if HitstopConfig.FreezePlayer then
		local character = LocalPlayer.Character
		if character then
			freezeCharacter(character)
		end
	end

	-- Freeze hit enemies
	if HitstopConfig.FreezeEnemies and hitTargets then
		for _, target in hitTargets do
			if target and target:IsA("Model") then
				freezeCharacter(target)
			end
		end
	end

	-- Schedule unfreeze
	task.delay(duration, function()
		unfreezeAll()
	end)
end

--[[
    Apply hitstop to a single target (called from server hit confirm)
]]
function HitstopController:ApplyToTarget(target: Model, duration: number)
	if not HitstopConfig.Enabled or not HitstopConfig.FreezeEnemies then
		return
	end

	duration = math.clamp(duration, HitstopConfig.MinDuration, HitstopConfig.MaxDuration)

	freezeCharacter(target)

	task.delay(duration, function()
		unfreezeCharacter(target)
	end)
end

--[[
    Force end hitstop (for dash cancel, etc.)
]]
function HitstopController:CancelHitstop()
	if isInHitstop then
		unfreezeAll()
	end
end

--[[
    Initialize the controller
]]
function HitstopController:Init()
	print("[HitstopController] Initialized")
end

--[[
    Start the controller
]]
function HitstopController:Start()
	-- Clean up on character death/respawn
	LocalPlayer.CharacterAdded:Connect(function()
		unfreezeAll()
	end)

	print("[HitstopController] Started")
end

--[[
    Cleanup
]]
function HitstopController:Destroy()
	unfreezeAll()
end

return HitstopController
