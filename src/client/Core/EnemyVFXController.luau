--[[
    EnemyVFXController.luau
    Client-side controller for enemy visual effects.
    Refactored to use VFXPool and VFXSystem.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))

local VFXPool = require(script.Parent.Parent.VFX.VFXPool)
local VFXSystem = require(script.Parent.Parent.VFX.VFXSystem)

local EnemyVFXController = {}
EnemyVFXController.Name = "EnemyVFXController"

-- Module references
local DamageNumbers = nil
local ScreenShakeController = nil
local AttackVFXPlayer = nil

local connections: { RBXScriptConnection } = {}
local lastPlayerHealth: number? = nil
local hitstunCooldowns: { [Model]: number } = {}
local HITSTUN_COOLDOWN = 0.25

-- Templates
local function getHighlightTemplate(name)
	local h = Instance.new("Highlight")
	h.Name = name
	h.FillColor = Color3.fromRGB(255, 255, 255)
	h.OutlineColor = Color3.fromRGB(255, 100, 100)
	h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	return h
end

local function getSmokeTemplate()
	local att = Instance.new("Attachment")
	att.Name = "DeathSmokeAtt"

	local p = Instance.new("ParticleEmitter")
	p.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(80, 80, 80)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(50, 50, 50)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(40, 40, 40)),
	})
	p.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.3, 3),
		NumberSequenceKeypoint.new(1, 5),
	})
	p.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(0.5, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	p.Lifetime = NumberRange.new(0.4, 0.8)
	p.Speed = NumberRange.new(5, 15)
	p.SpreadAngle = Vector2.new(180, 180)
	p.Drag = 3
	p.Rate = 0
	p.Parent = att
	return att
end

local function getImpactTemplate()
	local att = Instance.new("Attachment")
	att.Name = "ImpactAtt"
	local p = Instance.new("ParticleEmitter")
	p.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 200, 100)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 100, 50)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(200, 50, 50)),
	})
	p.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.8),
		NumberSequenceKeypoint.new(0.3, 0.5),
		NumberSequenceKeypoint.new(1, 0),
	})
	p.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.8, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	p.Lifetime = NumberRange.new(0.15, 0.3)
	p.Speed = NumberRange.new(10, 25)
	p.SpreadAngle = Vector2.new(180, 180)
	p.Rate = 0
	p.Parent = att
	return att
end

local function getDustTemplate()
	local att = Instance.new("Attachment")
	att.Name = "DustAtt"
	local p = Instance.new("ParticleEmitter")
	p.Color = ColorSequence.new(Color3.fromRGB(100, 90, 80))
	p.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 2),
		NumberSequenceKeypoint.new(0.5, 4),
		NumberSequenceKeypoint.new(1, 6),
	})
	p.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(0.5, 0.6),
		NumberSequenceKeypoint.new(1, 1),
	})
	p.Lifetime = NumberRange.new(0.5, 1.0)
	p.Speed = NumberRange.new(5, 15)
	p.SpreadAngle = Vector2.new(180, 30)
	p.Drag = 4
	p.Rate = 0
	p.Parent = att
	return att
end

-- ============================================================================
-- HELPERS
-- ============================================================================

local function createAttackIndicator(enemyModel: Model, _targetPosition: Vector3)
	local enemyRoot = enemyModel:FindFirstChild("HumanoidRootPart") or enemyModel.PrimaryPart
	if not enemyRoot then return end

	local highlight = VFXPool:Get("AttackHighlight", getHighlightTemplate("AttackHighlight"))
	highlight.Adornee = enemyModel
	highlight.FillColor = Color3.fromRGB(255, 50, 50)
	highlight.FillTransparency = 0.5
	highlight.OutlineColor = Color3.fromRGB(255, 0, 0)
	highlight.OutlineTransparency = 0.3
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = enemyModel

	VFXSystem:Add(highlight, 0.35, {
		FillTransparency = 0.3
	}, {
		EasingStyle = Enum.EasingStyle.Quad,
		PoolName = "AttackHighlight"
	})
end

-- ============================================================================
-- EVENT HANDLERS
-- ============================================================================

local function onEnemyAttack(data)
	local enemy = data.Enemy
	local hitPosition = data.HitPosition
	local damage = data.Damage
	local attackType = data.AttackType

	if hitPosition and AttackVFXPlayer then
		if attackType == "Slam" or (not attackType and data.IsSlam) then
			AttackVFXPlayer:Play("Slam", hitPosition, damage or 15)
		elseif attackType == "Swing" then
			AttackVFXPlayer:Play("Swing", hitPosition, damage or 12, enemy)
		elseif attackType == "LeapStart" then
			AttackVFXPlayer:Play("LeapStart", hitPosition, damage or 25, enemy)
		elseif attackType == "LeapSlam" then
			AttackVFXPlayer:Play("LeapSlam", hitPosition, damage or 25, enemy)
		end
	end

	if enemy then
		createAttackIndicator(enemy, hitPosition)
	end
end

local function onEnemyDied(data)
	local enemyModel = data.Target
	local position = data.Position

	if not enemyModel or not enemyModel.Parent then return end

	-- Disable raycasting
	for _, part in enemyModel:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanQuery = false
			part.CanTouch = false
		end
	end

	-- Smoke
	local smokePos = position or (enemyModel.PrimaryPart and enemyModel.PrimaryPart.Position)
	if smokePos then
		local att = VFXPool:Get("DeathSmokeAtt", getSmokeTemplate())
		att.WorldPosition = smokePos
		att.Parent = workspace.Terrain

		local p = att:FindFirstChild("ParticleEmitter")
		if p then p:Emit(15) end

		task.delay(1, function()
			VFXPool:Return(att, "DeathSmokeAtt")
		end)
	end

	-- Fade model parts
	-- Not pooled, just cleanup via server destroy eventually
	for _, part in enemyModel:GetDescendants() do
		if part:IsA("BasePart") then
			VFXSystem:Add(part, 0.3, { Transparency = 1 })
		end
	end
end

local function onDamageBlocked(data)
	-- Could add text here
end

local function onEnemySpawned(data)
	local enemyModel = data.Enemy
	local position = data.Position
	if not enemyModel then return end

	-- Dust
	local att = VFXPool:Get("DustAtt", getDustTemplate())
	att.WorldPosition = position or (enemyModel.PrimaryPart and enemyModel.PrimaryPart.Position) or enemyModel:GetPivot().Position
	att.Parent = workspace.Terrain
	local p = att:FindFirstChild("ParticleEmitter")
	if p then p:Emit(12) end
	task.delay(1.5, function() VFXPool:Return(att, "DustAtt") end)

	-- Scale Pop
	for _, part in enemyModel:GetDescendants() do
		if part:IsA("BasePart") then
			local originalSize = part.Size
			part.Size = originalSize * 0.3

			VFXSystem:Add(part, 0.3, {
				Size = originalSize
			}, {
				EasingStyle = Enum.EasingStyle.Back,
				EasingDirection = Enum.EasingDirection.Out
			})
		end
	end
end

local function onEnemyStateChanged(enemyModel, newState)
	if newState == "Hitstun" then
		EnemyVFXController:PlayHitstun(enemyModel)
	end
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

function EnemyVFXController:PlayHitstun(enemyModel: Model)
	if not enemyModel or not enemyModel.Parent then return end

	local now = os.clock()
	local lastHitstun = hitstunCooldowns[enemyModel]
	if lastHitstun and (now - lastHitstun) < HITSTUN_COOLDOWN then return end
	hitstunCooldowns[enemyModel] = now

	-- Clear cooldown later
	task.delay(1, function()
		if hitstunCooldowns[enemyModel] == now then
			hitstunCooldowns[enemyModel] = nil
		end
	end)

	local rootPart = enemyModel:FindFirstChild("HumanoidRootPart") or enemyModel.PrimaryPart
	if not rootPart then return end

	-- Highlight
	-- Remove old one first if exists (though pooling should handle it)
	local existing = enemyModel:FindFirstChild("HitstunHighlight")
	if existing then
		-- If it's pooled, we should return it properly?
		-- Or just destroy it if it's rogue.
		-- VFXSystem will handle return if it was added there.
		-- But if we force a new one, we might want to let the old one fade naturally or force cancel.
		-- Let's just create a new one, VFXSystem handles duplicates on same instance?
		-- No, duplicate keys in activeEffects.
		-- But here we create NEW instance from pool.
		-- So it's fine.
	end

	local highlight = VFXPool:Get("HitstunHighlight", getHighlightTemplate("HitstunHighlight"))
	highlight.Adornee = enemyModel
	highlight.FillColor = Color3.fromRGB(255, 255, 255)
	highlight.FillTransparency = 0
	highlight.OutlineTransparency = 0
	highlight.Parent = enemyModel

	VFXSystem:Play(highlight, 0.25, function(inst, alpha)
		-- alpha 0 -> 0.2 (Red Flash)
		if alpha < 0.2 then
			local t = alpha / 0.2
			inst.FillColor = Color3.fromRGB(255, 255, 255):Lerp(Color3.fromRGB(255, 50, 50), t)
			inst.FillTransparency = 0.2 * t
		else
			-- alpha 0.2 -> 1 (Fade)
			local t = (alpha - 0.2) / 0.8
			inst.FillTransparency = 0.2 + (0.8 * t)
			inst.OutlineTransparency = t
		end
	end, {
		PoolName = "HitstunHighlight"
	})

	-- Particles
	local att = VFXPool:Get("ImpactAtt", getImpactTemplate())
	att.WorldPosition = rootPart.Position
	att.Parent = workspace.Terrain
	local p = att:FindFirstChild("ParticleEmitter")
	if p then p:Emit(12) end
	task.delay(0.5, function() VFXPool:Return(att, "ImpactAtt") end)
end

-- ============================================================================
-- LIFECYCLE
-- ============================================================================

function EnemyVFXController:Init()
	local function tryRequire(path)
		local success, result = pcall(function() return require(path) end)
		return success and result or nil
	end

	DamageNumbers = tryRequire(script.Parent.Parent.VFX.DamageNumbers)
	ScreenShakeController = tryRequire(script.Parent.Parent.VFX.ScreenShakeController)
	AttackVFXPlayer = tryRequire(script.Parent.Parent.VFX.AttackVFXPlayer)

	if AttackVFXPlayer then
		AttackVFXPlayer:Init(ScreenShakeController)
	end

	print("[EnemyVFXController] Initialized")
end

function EnemyVFXController:Start()
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

	local LocalPlayer = Players.LocalPlayer

	local function onCharacterAdded(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
		if not humanoid then return end

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

function EnemyVFXController:Destroy()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

return EnemyVFXController
