--[[
    EnemyVFXController.luau
    OPTIMIZED DRAFT - 2024-05-22

    Optimizations Applied:
    1.  **Highlight Manager**: Implemented a pooled Highlight system with a strict cap (15) to prevent exceeding Roblox's 31-instance limit.
        - Prevents rendering crashes on mobile.
        - Reuses Highlight instances.
    2.  **Particle Pooling**: Reused the `VFXPool` pattern for impact particles and smoke.
    3.  **Connection Tracking**: Improved connection management for health listeners.
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

-- Hitstun cooldown tracking
local hitstunCooldowns: { [Model]: number } = {}
local HITSTUN_COOLDOWN = 0.25

-- ============================================================================
-- OPTIMIZATION: Pooling Systems
-- ============================================================================

local function createPool(createFunc, resetFunc, maxCapacity)
	local pool = {}
	maxCapacity = maxCapacity or 20
	return {
		Get = function(...)
			local item = table.remove(pool)
			if not item then item = createFunc(...) end
			return item
		end,
		Return = function(item)
			if #pool < maxCapacity then
				if resetFunc then resetFunc(item) end
				table.insert(pool, item)
			else
				if typeof(item) == "Instance" then item:Destroy() end
			end
		end
	}
end

-- Highlight Manager (Strict Limit for Mobile)
local MAX_HIGHLIGHTS = 15
local highlightPool = {}
local activeHighlights = {} -- [Model] = { Highlight, ExpiryTime }

local function getHighlight(adornee)
    if activeHighlights[adornee] then return activeHighlights[adornee].Highlight end

    local h = table.remove(highlightPool)
    if not h then
        -- Check cap
        local count = 0
        for _ in activeHighlights do count += 1 end

        if count >= MAX_HIGHLIGHTS then
             return nil -- Fail silently to save perf
        end
        h = Instance.new("Highlight")
    end

    h.Adornee = adornee
    h.Parent = adornee
    activeHighlights[adornee] = { Highlight = h, ExpiryTime = os.clock() + 5 } -- Safety expiry
    return h
end

local function releaseHighlight(adornee)
    local data = activeHighlights[adornee]
    if data then
        local h = data.Highlight
        h.Adornee = nil
        h.Parent = nil
        activeHighlights[adornee] = nil
        table.insert(highlightPool, h)
    end
end

-- Particle Pool (Smoke/Impact)
local particlePool = createPool(function()
    local att = Instance.new("Attachment")
    local emit = Instance.new("ParticleEmitter")
    emit.Parent = att
    return { Attachment = att, Emitter = emit }
end, function(item)
    item.Attachment.Parent = nil
end, 30)


-- ============================================================================
-- ATTACK INDICATOR
-- ============================================================================

local function createAttackIndicator(enemyModel: Model, _targetPosition: Vector3)
	local enemyRoot = enemyModel:FindFirstChild("HumanoidRootPart")
		or enemyModel:FindFirstChild("Torso")
		or enemyModel.PrimaryPart

	if not enemyRoot then return end

	-- OPTIMIZATION: Use Highlight Manager
	local highlight = getHighlight(enemyModel)
    if not highlight then return end -- Pool full

	highlight.FillColor = Color3.fromRGB(255, 50, 50)
	highlight.FillTransparency = 0.5
	highlight.OutlineColor = Color3.fromRGB(255, 0, 0)
	highlight.OutlineTransparency = 0.3
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded

	local flashTween = TweenService:Create(
		highlight,
		TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ FillTransparency = 0.3 }
	)
	flashTween:Play()

	task.delay(0.35, function()
        releaseHighlight(enemyModel)
    end)
end

-- ============================================================================
-- EVENT HANDLERS
-- ============================================================================

local function onEnemyAttack(data)
	local enemy = data.Enemy
	local target = data.Target
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

	if enemy and target then
		createAttackIndicator(enemy, hitPosition)
	end
end

local function onEnemyDied(data)
	local enemyModel = data.Target
	local position = data.Position
	if not enemyModel or not enemyModel.Parent then return end

	for _, part in enemyModel:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanQuery = false
			part.CanTouch = false
		end
	end

	local smokePos = position or (enemyModel.PrimaryPart and enemyModel.PrimaryPart.Position)
	if smokePos then
        -- OPTIMIZATION: Use Pool
        local item = particlePool.Get()
		local attachment = item.Attachment
        local smokeParticles = item.Emitter

		attachment.WorldPosition = smokePos
		attachment.Parent = workspace.Terrain

		smokeParticles.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(80, 80, 80)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(50, 50, 50)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(40, 40, 40)),
		})
		smokeParticles.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 5)})
		smokeParticles.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1)})
		smokeParticles.Lifetime = NumberRange.new(0.4, 0.8)
        smokeParticles.Rate = 0
		smokeParticles:Emit(15)

        task.delay(1, function()
            particlePool.Return(item)
        end)
	end

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
end

local function onDamageBlocked(data)
	-- Visual feedback for dodge
end

local function onEnemySpawned(data)
	local enemyModel = data.Enemy
	local position = data.Position
	if not enemyModel then return end

    -- OPTIMIZATION: Use Pool
    local item = particlePool.Get()
    local attachment = item.Attachment
    local spawnSmoke = item.Emitter

	attachment.WorldPosition = position
		or (enemyModel.PrimaryPart and enemyModel.PrimaryPart.Position)
		or enemyModel:GetPivot().Position
	attachment.Parent = workspace.Terrain

	spawnSmoke.Color = ColorSequence.new(Color3.fromRGB(100, 90, 80))
	spawnSmoke.Lifetime = NumberRange.new(0.5, 1.0)
    spawnSmoke.Rate = 0
	spawnSmoke:Emit(12)

	task.delay(1.5, function()
        particlePool.Return(item)
    end)

	for _, part in enemyModel:GetDescendants() do
		if part:IsA("BasePart") then
			local originalSize = part.Size
			part.Size = originalSize * 0.3
			TweenService:Create(part, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = originalSize }):Play()
		end
	end
end

local function onEnemyStateChanged(enemyModel: Model, newState: string)
	if not enemyModel or not enemyModel.Parent then return end
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

	local rootPart = enemyModel:FindFirstChild("HumanoidRootPart") or enemyModel.PrimaryPart
	if not rootPart then return end

	-- OPTIMIZATION: Use Highlight Manager
	local highlight = getHighlight(enemyModel)
	if highlight then
        highlight.FillColor = Color3.fromRGB(255, 255, 255)
        highlight.FillTransparency = 0
        highlight.OutlineColor = Color3.fromRGB(255, 100, 100)
        highlight.OutlineTransparency = 0
        highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop

        task.spawn(function()
            -- Manual fade without creating tween
            for i=1, 5 do
                task.wait(0.04)
                if highlight.Parent ~= enemyModel then break end
                highlight.FillTransparency = i/5
                highlight.OutlineTransparency = i/5
            end
            releaseHighlight(enemyModel)
        end)
    end

	-- OPTIMIZATION: Use Particle Pool
    local item = particlePool.Get()
    local attachment = item.Attachment
    local impactParticles = item.Emitter

	attachment.WorldPosition = rootPart.Position
	attachment.Parent = workspace.Terrain

    impactParticles.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 200, 100)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(200, 50, 50)),
	})
    impactParticles.Rate = 0
    impactParticles:Emit(12)

    task.delay(0.5, function()
        particlePool.Return(item)
    end)

	task.delay(1, function()
		if hitstunCooldowns[enemyModel] == now then
			hitstunCooldowns[enemyModel] = nil
		end
	end)
end

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

	print("[EnemyVFXController] Initialized (Optimized)")
end

function EnemyVFXController:Start()
	local enemyAttackRemote = Remotes:GetEvent("EnemyAttack")
	if enemyAttackRemote then table.insert(connections, enemyAttackRemote.OnClientEvent:Connect(onEnemyAttack)) end

	local enemyDiedRemote = Remotes:GetEvent("EnemyDied")
	if enemyDiedRemote then table.insert(connections, enemyDiedRemote.OnClientEvent:Connect(onEnemyDied)) end

	local enemySpawnedRemote = Remotes:GetEvent("EnemySpawned")
	if enemySpawnedRemote then table.insert(connections, enemySpawnedRemote.OnClientEvent:Connect(onEnemySpawned)) end

	local damageBlockedRemote = Remotes:GetEvent("DamageBlocked")
	if damageBlockedRemote then table.insert(connections, damageBlockedRemote.OnClientEvent:Connect(onDamageBlocked)) end

	local stateRemote = Remotes:GetEvent("EnemyStateChanged")
	if stateRemote then table.insert(connections, stateRemote.OnClientEvent:Connect(onEnemyStateChanged)) end

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
				if DamageNumbers then DamageNumbers:SpawnOnCharacter(character, delta, "Normal") end
				if ScreenShakeController then
					local intensity = math.clamp(delta / 30, 0.15, 0.6)
					ScreenShakeController:Shake(intensity, 0.15)
				end
			end
		end)
		table.insert(connections, healthConn)
	end

	if LocalPlayer.Character then task.spawn(onCharacterAdded, LocalPlayer.Character) end
	table.insert(connections, LocalPlayer.CharacterAdded:Connect(onCharacterAdded))

	print("[EnemyVFXController] Started")
end

function EnemyVFXController:Destroy()
	for _, connection in connections do connection:Disconnect() end
	table.clear(connections)
end

return EnemyVFXController
