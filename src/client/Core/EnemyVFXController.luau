--[[
    EnemyVFXController.luau
    Client-side controller for enemy visual effects.
    
    Listens to server events and plays VFX:
    - Enemy attack effects (when enemy attacks player)
    - Enemy spawn effects
    - Enemy death effects (ragdoll, fade out)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))

local EnemyVFXController = {}
EnemyVFXController.Name = "EnemyVFXController"

-- References to VFX modules (set in Init)
local DamageNumbers = nil
local ScreenShakeController = nil

-- Connections
local connections: { RBXScriptConnection } = {}

-- Hitstun cooldown tracking to prevent double-application
-- Key: enemy Model, Value: last hitstun time
local hitstunCooldowns: { [Model]: number } = {}
local HITSTUN_COOLDOWN = 0.25 -- Minimum time between hitstun effects on same enemy

--[[
    Create attack warning indicator at enemy position
]]
local function createAttackIndicator(enemyModel: Model, targetPosition: Vector3)
	local enemyRoot = enemyModel:FindFirstChild("HumanoidRootPart")
		or enemyModel:FindFirstChild("Torso")
		or enemyModel.PrimaryPart

	if not enemyRoot then
		return
	end

	-- Create a red flash effect on the enemy to telegraph attack
	local highlight = Instance.new("Highlight")
	highlight.Adornee = enemyModel
	highlight.FillColor = Color3.fromRGB(255, 50, 50)
	highlight.FillTransparency = 0.7
	highlight.OutlineColor = Color3.fromRGB(255, 0, 0)
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = enemyModel

	-- Flash animation
	local flashTween = TweenService:Create(
		highlight,
		TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, 1, true),
		{ FillTransparency = 0.3 }
	)
	flashTween:Play()

	-- Cleanup after flash
	Debris:AddItem(highlight, 0.35)
end

--[[
    Handle enemy attack event
    Shows damage taken and screen shake when player is hit
]]
local function onEnemyAttack(data)
	-- data = { Enemy, Target, HitPosition, Damage }

	local enemy = data.Enemy
	local target = data.Target
	local hitPosition = data.HitPosition
	local damage = data.Damage

	-- Create attack telegraph on enemy
	if enemy and target then
		createAttackIndicator(enemy, hitPosition)
	end

	-- If we're the target, show effects
	local Players = game:GetService("Players")
	local LocalPlayer = Players.LocalPlayer

	if target == LocalPlayer then
		-- Screen shake (we got hit!)
		if ScreenShakeController then
			ScreenShakeController:Shake(0.5, 0.15)
		end

		-- Damage number on our character (shows damage we took)
		if DamageNumbers and LocalPlayer.Character then
			DamageNumbers:SpawnOnCharacter(LocalPlayer.Character, damage, "Normal")
		end

		-- Red vignette flash (screen damage indicator)
		-- This would be implemented in a ScreenEffects module
	end
end

--[[
    Handle enemy death event
    Creates instant death effects - NO RAGDOLL to avoid blocking shots
    
    Death Effect: Smoke burst + rapid dissolve
    - Immediately disables raycasting so dead enemies don't block shots
    - Quick dissolve animation (0.3s)
    - Smoke particle burst at death position
]]
local function onEnemyDied(data)
	-- data = { Target, Killer, Position }

	local enemyModel = data.Target
	local position = data.Position

	if not enemyModel or not enemyModel.Parent then
		return
	end

	local rootPart = enemyModel:FindFirstChild("HumanoidRootPart")
		or enemyModel:FindFirstChild("Torso")
		or enemyModel.PrimaryPart

	local deathPosition = rootPart and rootPart.Position or position

	-- IMMEDIATELY disable all physics interactions
	-- This is critical to prevent dead enemies from blocking shots
	for _, part in enemyModel:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanCollide = false
			part.CanQuery = false -- Don't block raycasts!
			part.CanTouch = false
			part.Anchored = true -- Freeze in place (no ragdoll)
		end
	end

	-- === DEATH VFX: Smoke Burst ===
	local smokeAttachment = Instance.new("Attachment")
	smokeAttachment.WorldPosition = deathPosition
	smokeAttachment.Parent = workspace.Terrain

	-- Smoke particles
	local smokeParticles = Instance.new("ParticleEmitter")
	smokeParticles.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(80, 80, 80)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(40, 40, 40)),
	})
	smokeParticles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.3, 3),
		NumberSequenceKeypoint.new(1, 5),
	})
	smokeParticles.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(0.5, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	smokeParticles.Lifetime = NumberRange.new(0.4, 0.8)
	smokeParticles.Speed = NumberRange.new(5, 15)
	smokeParticles.SpreadAngle = Vector2.new(180, 180)
	smokeParticles.Rate = 0
	smokeParticles.Parent = smokeAttachment

	-- Emit smoke burst
	smokeParticles:Emit(20)

	-- Cleanup smoke after particles finish
	Debris:AddItem(smokeAttachment, 1)

	-- === DEATH VFX: Rapid Dissolve ===
	-- Quick fade (0.3s) so enemy disappears fast
	local dissolveDuration = 0.3

	for _, part in enemyModel:GetDescendants() do
		if part:IsA("BasePart") then
			-- Shrink and fade simultaneously
			local dissolveTween = TweenService:Create(
				part,
				TweenInfo.new(dissolveDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{
					Transparency = 1,
					Size = part.Size * 0.1, -- Shrink to 10%
				}
			)
			dissolveTween:Play()
		elseif part:IsA("Decal") or part:IsA("Texture") then
			local fadeTween = TweenService:Create(
				part,
				TweenInfo.new(dissolveDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Transparency = 1 }
			)
			fadeTween:Play()
		end
	end

	-- NOTE: We do NOT destroy the model here!
	-- The server owns the model and will destroy it via EnemyService.
	-- Client only handles visual effects (fade/shrink).
	-- Destroying here would cause replication issues.
end

--[[
    Handle damage blocked event (player dodged with I-frames)
    Shows "DODGE" text and visual feedback
]]
local function onDamageBlocked(data)
	-- data = { Enemy, Position, DamageBlocked }

	local position = data.Position
	local damageBlocked = data.DamageBlocked

	-- Show "DODGE" damage number
	if DamageNumbers then
		DamageNumbers:SpawnText(position + Vector3.new(0, 2, 0), "DODGE", "Dodge")
	end

	-- White flash on screen edge (optional subtle feedback)
	-- Could be implemented via ScreenEffects module

	-- Brief slow-mo feel (optional - tiny hitstop for satisfaction)
	-- This would call HitstopController if we want that feel
end

--[[
    Handle enemy spawn event
    Creates spawn effects
]]
local function onEnemySpawned(data)
	-- data = { Enemy, Position, EnemyType }

	local enemyModel = data.Enemy
	local position = data.Position

	if not enemyModel then
		return
	end

	-- Spawn dust/smoke effect
	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = position
	attachment.Parent = workspace.Terrain

	local particles = Instance.new("ParticleEmitter")
	particles.Color = ColorSequence.new(Color3.fromRGB(100, 100, 100))
	particles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 2),
		NumberSequenceKeypoint.new(1, 0),
	})
	particles.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	particles.Lifetime = NumberRange.new(0.5, 1)
	particles.Speed = NumberRange.new(5, 10)
	particles.SpreadAngle = Vector2.new(180, 180)
	particles.Rate = 0
	particles.Parent = attachment

	particles:Emit(15)

	Debris:AddItem(attachment, 1.5)

	-- Scale-in effect on enemy
	for _, part in enemyModel:GetDescendants() do
		if part:IsA("BasePart") then
			local originalSize = part.Size
			part.Size = originalSize * 0.1

			local scaleTween = TweenService:Create(
				part,
				TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Size = originalSize }
			)
			scaleTween:Play()
		end
	end
end

--[[
    Handle enemy state change event
    Plays visual effects based on new state (e.g. hitstun flinch)
]]
local function onEnemyStateChanged(enemyModel: Model, newState: string)
	if not enemyModel or not enemyModel.Parent then
		return
	end

	local rootPart = enemyModel:FindFirstChild("HumanoidRootPart")
		or enemyModel:FindFirstChild("Torso")
		or enemyModel.PrimaryPart

	if not rootPart then
		return
	end

	if newState == "Hitstun" then
		EnemyVFXController:PlayHitstun(enemyModel)
	end
end

--[[
    Play hitstun VFX immediately (Public for client prediction)
    
    IMPORTANT: This function uses VISUAL-ONLY feedback (Highlights, particles).
    It does NOT manipulate the enemy's CFrame or Size, which would conflict with 
    Humanoid physics or attached UI elements like health bars.
    
    Effects:
    - Intense white->red highlight flash
    - Impact particles burst
]]
function EnemyVFXController:PlayHitstun(enemyModel: Model)
	if not enemyModel or not enemyModel.Parent then
		return
	end

	-- Cooldown check to prevent double-application from prediction + server broadcast
	local now = os.clock()
	local lastHitstun = hitstunCooldowns[enemyModel]
	if lastHitstun and (now - lastHitstun) < HITSTUN_COOLDOWN then
		return -- Already playing hitstun effect, skip
	end
	hitstunCooldowns[enemyModel] = now

	local rootPart = enemyModel:FindFirstChild("HumanoidRootPart")
		or enemyModel:FindFirstChild("Torso")
		or enemyModel.PrimaryPart

	if not rootPart then
		return
	end

	-- === EFFECT 1: INTENSE HIGHLIGHT FLASH ===
	-- Destroy any existing hitstun highlight
	local existingHighlight = enemyModel:FindFirstChild("HitstunHighlight")
	if existingHighlight then
		existingHighlight:Destroy()
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = "HitstunHighlight"
	highlight.Adornee = enemyModel
	-- Start with bright WHITE for maximum impact
	highlight.FillColor = Color3.fromRGB(255, 255, 255)
	highlight.FillTransparency = 0 -- Fully opaque!
	highlight.OutlineColor = Color3.fromRGB(255, 100, 100)
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Parent = enemyModel

	-- Animate highlight: white -> red -> fade out
	task.spawn(function()
		-- Hold white flash briefly
		task.wait(0.05)
		if not highlight or not highlight.Parent then
			return
		end

		-- Transition to red
		highlight.FillColor = Color3.fromRGB(255, 50, 50)
		highlight.FillTransparency = 0.2

		task.wait(0.05)
		if not highlight or not highlight.Parent then
			return
		end

		-- Fade out
		local fadeSteps = 4
		for i = 1, fadeSteps do
			task.wait(0.04)
			if not highlight or not highlight.Parent then
				return
			end

			local alpha = i / fadeSteps
			highlight.FillTransparency = 0.2 + (0.8 * alpha)
			highlight.OutlineTransparency = alpha
		end

		-- Cleanup
		if highlight and highlight.Parent then
			highlight:Destroy()
		end
	end)

	-- === EFFECT 2: IMPACT PARTICLES ===
	-- NOTE: Size pulse removed - it was causing issues with attached health bars
	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = rootPart.Position
	attachment.Parent = workspace.Terrain

	-- Red/orange impact sparks
	local impactParticles = Instance.new("ParticleEmitter")
	impactParticles.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 200, 100)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 100, 50)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(200, 50, 50)),
	})
	impactParticles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.8),
		NumberSequenceKeypoint.new(0.3, 0.5),
		NumberSequenceKeypoint.new(1, 0),
	})
	impactParticles.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.8, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	impactParticles.Lifetime = NumberRange.new(0.15, 0.3)
	impactParticles.Speed = NumberRange.new(10, 25)
	impactParticles.SpreadAngle = Vector2.new(180, 180)
	impactParticles.Rate = 0
	impactParticles.Parent = attachment

	-- Emit burst
	impactParticles:Emit(12)

	-- Cleanup particles
	Debris:AddItem(attachment, 0.5)

	-- Cleanup cooldown entry after a delay
	task.delay(1, function()
		if hitstunCooldowns[enemyModel] == now then
			hitstunCooldowns[enemyModel] = nil
		end
	end)
end

--[[
    Initialize the controller
]]
function EnemyVFXController:Init()
	-- Get VFX modules
	local function tryRequire(path)
		local success, result = pcall(function()
			return require(path)
		end)
		return success and result or nil
	end

	DamageNumbers = tryRequire(script.Parent.Parent.VFX.DamageNumbers)
	ScreenShakeController = tryRequire(script.Parent.Parent.VFX.ScreenShakeController)

	print("[EnemyVFXController] Initialized")
end

--[[
    Start the controller
]]
function EnemyVFXController:Start()
	-- Connect to remote events
	local enemyAttackRemote = Remotes:GetEvent("EnemyAttack")
	if enemyAttackRemote then
		table.insert(connections, enemyAttackRemote.OnClientEvent:Connect(onEnemyAttack))
	end

	local enemyDiedRemote = Remotes:GetEvent("EnemyDied")
	if enemyDiedRemote then
		table.insert(connections, enemyDiedRemote.OnClientEvent:Connect(onEnemyDied))
	end

	local enemySpawnedRemote = Remotes:GetEvent("EnemySpawned")
	if enemySpawnedRemote then
		table.insert(connections, enemySpawnedRemote.OnClientEvent:Connect(onEnemySpawned))
	end

	local damageBlockedRemote = Remotes:GetEvent("DamageBlocked")
	if damageBlockedRemote then
		table.insert(connections, damageBlockedRemote.OnClientEvent:Connect(onDamageBlocked))
	end

	local stateRemote = Remotes:GetEvent("EnemyStateChanged")
	if stateRemote then
		table.insert(connections, stateRemote.OnClientEvent:Connect(onEnemyStateChanged))
	end

	print("[EnemyVFXController] Started")
end

--[[
    Cleanup
]]
function EnemyVFXController:Destroy()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

return EnemyVFXController
