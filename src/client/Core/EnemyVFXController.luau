--[[
    EnemyVFXController.luau
    Client-side controller for enemy visual effects.
    
    Orchestrates VFX by listening to server events and dispatching to
    specialized modules:
    - Attack VFX → AttackVFXPlayer (data-driven from AttackVFXConfig)
    - Damage numbers → DamageNumbers module
    - Screen shake → ScreenShakeController module
    
    Also handles: spawn effects, death effects, hitstun, damage blocked.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))

local EnemyVFXController = {}
EnemyVFXController.Name = "EnemyVFXController"

-- Module references (set in Init)
local DamageNumbers = nil
local ScreenShakeController = nil
local AttackVFXPlayer = nil

-- Connections
local connections: { RBXScriptConnection } = {}

-- Track player health for damage numbers on actual hits
local lastPlayerHealth: number? = nil

-- Hitstun cooldown tracking to prevent double-application
-- Key: enemy Model, Value: last hitstun time
local hitstunCooldowns: { [Model]: number } = {}
local HITSTUN_COOLDOWN = 0.25 -- Minimum time between hitstun effects on same enemy

-- ============================================================================
-- ATTACK INDICATOR
-- ============================================================================

--[[
    Create attack warning indicator at enemy position
]]
local function createAttackIndicator(enemyModel: Model, _targetPosition: Vector3)
	local enemyRoot = enemyModel:FindFirstChild("HumanoidRootPart")
		or enemyModel:FindFirstChild("Torso")
		or enemyModel.PrimaryPart

	if not enemyRoot then
		return
	end

	-- Quick red highlight flash on the enemy
	local highlight = Instance.new("Highlight")
	highlight.Adornee = enemyModel
	highlight.FillColor = Color3.fromRGB(255, 50, 50)
	highlight.FillTransparency = 0.5
	highlight.OutlineColor = Color3.fromRGB(255, 0, 0)
	highlight.OutlineTransparency = 0.3
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = enemyModel

	local flashTween = TweenService:Create(
		highlight,
		TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ FillTransparency = 0.3 }
	)
	flashTween:Play()

	-- Cleanup after flash
	Debris:AddItem(highlight, 0.35)
end

-- ============================================================================
-- EVENT HANDLERS
-- ============================================================================

--[[
    Handle enemy attack event
    Routes to AttackVFXPlayer for attack-specific VFX
]]
local function onEnemyAttack(data)
	-- data = { Enemy, Target, HitPosition, Damage, AttackType, IsSlam }

	local enemy = data.Enemy
	local target = data.Target
	local hitPosition = data.HitPosition
	local damage = data.Damage
	local attackType = data.AttackType

	-- Attack-specific VFX via the player module
	if hitPosition and AttackVFXPlayer then
		if attackType == "Slam" or (not attackType and data.IsSlam) then
			AttackVFXPlayer:Play("Slam", hitPosition, damage or 15)
		elseif attackType == "Swing" then
			AttackVFXPlayer:Play("Swing", hitPosition, damage or 12, enemy)
		end
	end

	-- Create attack telegraph on enemy
	if enemy and target then
		createAttackIndicator(enemy, hitPosition)
	end
end

--[[
    Handle enemy death event
    Death Effect: Smoke burst + rapid dissolve
]]
local function onEnemyDied(data)
	-- data = { Target, Killer, Position }

	local enemyModel = data.Target
	local position = data.Position

	if not enemyModel or not enemyModel.Parent then
		return
	end

	-- Immediately disable raycasting so dead enemies don't block shots
	for _, part in enemyModel:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanQuery = false
			part.CanTouch = false
		end
	end

	-- Smoke burst at death position
	local smokePos = position or (enemyModel.PrimaryPart and enemyModel.PrimaryPart.Position)
	if smokePos then
		local attachment = Instance.new("Attachment")
		attachment.WorldPosition = smokePos
		attachment.Parent = workspace.Terrain

		local smokeParticles = Instance.new("ParticleEmitter")
		smokeParticles.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(80, 80, 80)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(50, 50, 50)),
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
		smokeParticles.Drag = 3
		smokeParticles.Rate = 0
		smokeParticles.Parent = attachment
		smokeParticles:Emit(15)

		Debris:AddItem(attachment, 1)
	end

	-- Quick dissolve: fade all parts
	for _, part in enemyModel:GetDescendants() do
		if part:IsA("BasePart") then
			local fadeTween = TweenService:Create(
				part,
				TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
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
]]
local function onDamageBlocked(data)
	-- data = { Enemy, Position, DamageBlocked }

	local _position = data.Position
	local _damageBlocked = data.DamageBlocked

	-- Visual feedback for dodge (flash screen edges or show "DODGE" text)
	-- Could be implemented via ScreenEffects module

	-- Brief slow-mo feel (optional - tiny hitstop for satisfaction)
	-- This would call HitstopController if we want that feel
end

--[[
    Handle enemy spawn event
    Creates spawn dust/smoke and scale pop effect
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
		or (enemyModel.PrimaryPart and enemyModel.PrimaryPart.Position)
		or enemyModel:GetPivot().Position
	attachment.Parent = workspace.Terrain

	local spawnSmoke = Instance.new("ParticleEmitter")
	spawnSmoke.Color = ColorSequence.new(Color3.fromRGB(100, 90, 80))
	spawnSmoke.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 2),
		NumberSequenceKeypoint.new(0.5, 4),
		NumberSequenceKeypoint.new(1, 6),
	})
	spawnSmoke.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(0.5, 0.6),
		NumberSequenceKeypoint.new(1, 1),
	})
	spawnSmoke.Lifetime = NumberRange.new(0.5, 1.0)
	spawnSmoke.Speed = NumberRange.new(5, 15)
	spawnSmoke.SpreadAngle = Vector2.new(180, 30)
	spawnSmoke.Drag = 4
	spawnSmoke.Rate = 0
	spawnSmoke.Parent = attachment
	spawnSmoke:Emit(12)

	Debris:AddItem(attachment, 1.5)

	-- Scale pop: briefly shrink then pop to normal size
	for _, part in enemyModel:GetDescendants() do
		if part:IsA("BasePart") then
			local originalSize = part.Size
			part.Size = originalSize * 0.3 -- Start small

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

-- ============================================================================
-- PUBLIC API
-- ============================================================================

--[[
    Play hitstun VFX immediately (Public for client prediction)
    
    IMPORTANT: Uses VISUAL-ONLY feedback (Highlights, particles).
    Does NOT manipulate enemy CFrame or Size, which would conflict with 
    Humanoid physics or attached UI elements like health bars.
    
    Effects:
    - Intense white→red highlight flash
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
		return
	end
	hitstunCooldowns[enemyModel] = now

	local rootPart = enemyModel:FindFirstChild("HumanoidRootPart")
		or enemyModel:FindFirstChild("Torso")
		or enemyModel.PrimaryPart

	if not rootPart then
		return
	end

	-- === HIGHLIGHT FLASH ===
	local existingHighlight = enemyModel:FindFirstChild("HitstunHighlight")
	if existingHighlight then
		existingHighlight:Destroy()
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = "HitstunHighlight"
	highlight.Adornee = enemyModel
	highlight.FillColor = Color3.fromRGB(255, 255, 255)
	highlight.FillTransparency = 0
	highlight.OutlineColor = Color3.fromRGB(255, 100, 100)
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Parent = enemyModel

	-- Animate: white → red → fade out
	task.spawn(function()
		task.wait(0.05)
		if not highlight or not highlight.Parent then
			return
		end

		highlight.FillColor = Color3.fromRGB(255, 50, 50)
		highlight.FillTransparency = 0.2

		task.wait(0.05)
		if not highlight or not highlight.Parent then
			return
		end

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

		if highlight and highlight.Parent then
			highlight:Destroy()
		end
	end)

	-- === IMPACT PARTICLES ===
	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = rootPart.Position
	attachment.Parent = workspace.Terrain

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
	impactParticles:Emit(12)

	Debris:AddItem(attachment, 0.5)

	-- Cleanup cooldown entry
	task.delay(1, function()
		if hitstunCooldowns[enemyModel] == now then
			hitstunCooldowns[enemyModel] = nil
		end
	end)
end

-- ============================================================================
-- LIFECYCLE
-- ============================================================================

--[[
    Initialize the controller
]]
function EnemyVFXController:Init()
	local function tryRequire(path)
		local success, result = pcall(function()
			return require(path)
		end)
		return success and result or nil
	end

	DamageNumbers = tryRequire(script.Parent.Parent.VFX.DamageNumbers)
	ScreenShakeController = tryRequire(script.Parent.Parent.VFX.ScreenShakeController)
	AttackVFXPlayer = tryRequire(script.Parent.Parent.VFX.AttackVFXPlayer)

	-- Pass screen shake controller to the attack VFX player
	if AttackVFXPlayer then
		AttackVFXPlayer:Init(ScreenShakeController)
	end

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

	-- Listen for player health changes to show damage numbers on actual hits
	local LocalPlayer = Players.LocalPlayer

	local function onCharacterAdded(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
		if not humanoid then
			return
		end

		lastPlayerHealth = humanoid.Health

		local healthConn = humanoid.HealthChanged:Connect(function(newHealth: number)
			local oldHealth = lastPlayerHealth or humanoid.MaxHealth
			lastPlayerHealth = newHealth

			local delta = oldHealth - newHealth
			if delta > 0 then
				if DamageNumbers then
					DamageNumbers:SpawnOnCharacter(character, delta, "Normal")
				end
				if ScreenShakeController then
					local intensity = math.clamp(delta / 30, 0.15, 0.6)
					ScreenShakeController:Shake(intensity, 0.15)
				end
			end
		end)
		table.insert(connections, healthConn)
	end

	if LocalPlayer.Character then
		task.spawn(onCharacterAdded, LocalPlayer.Character)
	end
	table.insert(connections, LocalPlayer.CharacterAdded:Connect(onCharacterAdded))

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
