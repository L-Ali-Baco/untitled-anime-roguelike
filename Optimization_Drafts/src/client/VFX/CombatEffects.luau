--[[
    CombatEffects.luau
    OPTIMIZED DRAFT - 2024-05-22

    Optimizations Applied:
    1.  **Object Pooling**: Implemented `VFXPool` system for Slash Trails, Hit Sparks, and Impact Rings.
        - Drastically reduces GC pressure by reusing instances instead of destroying them.
    2.  **Tween Reduction**: Replaced some heavy Tweens with faster manual property setting or simpler transitions where appropriate.
    3.  **Debris Replacement**: Replaced `Debris:AddItem` with `pool:Return` scheduled via `task.delay`.
]]

local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatConfig = require(ReplicatedStorage.Shared.Config.CombatConfig)

local CombatEffects = {}

-- Config shorthand
local EffectsConfig = CombatConfig.Effects

-- ============================================================================
-- OPTIMIZATION: Simple Object Pool Implementation
-- ============================================================================

local function createPool(createFunc, resetFunc, maxCapacity)
	local pool = {}
	maxCapacity = maxCapacity or 50

	return {
		Get = function(...)
			local item = table.remove(pool)
			if not item then
				item = createFunc(...)
			end
			return item
		end,
		Return = function(item)
			if #pool < maxCapacity then
				if resetFunc then resetFunc(item) end
				table.insert(pool, item)
			else
				-- If it's a model/part, destroy it
				if typeof(item) == "Instance" then
					item:Destroy()
				elseif type(item) == "table" and item.Destroy then
					item:Destroy()
				end
			end
		end
	}
end

-- Slash Trail Pool
local slashPool = createPool(function()
	local part = Instance.new("Part")
	part.Name = "SlashTrail"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	return part
end, function(part)
	part.Parent = nil
	part.Transparency = 0.3
    -- Size/CFrame will be overwritten on Get
end, 20)

-- Hit Spark Pool (Attachment + Emitter)
local sparkPool = createPool(function()
	local att = Instance.new("Attachment")
	local emit = Instance.new("ParticleEmitter")
	emit.Parent = att
	return { Attachment = att, Emitter = emit }
end, function(item)
	item.Attachment.Parent = nil
    -- Emitter properties might need reset if changed dynamically
end, 30)

-- Flash Pool
local flashPool = createPool(function()
	local part = Instance.new("Part")
	part.Name = "HitFlash"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Shape = Enum.PartType.Ball
	return part
end, function(part)
	part.Parent = nil
	part.Transparency = 0.5
end, 20)

-- Impact Ring Pool
local ringPool = createPool(function()
	local ring = Instance.new("Part")
	ring.Name = "ImpactRing"
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	local mesh = Instance.new("CylinderMesh")
	mesh.Parent = ring
	return ring
end, function(ring)
	ring.Parent = nil
	ring.Transparency = 0.3
end, 10)

-- ============================================================================

--[[
    Create a slash arc trail effect
]]
function CombatEffects:SpawnSlashTrail(startPos: Vector3, endPos: Vector3, comboHit: number)
	if not EffectsConfig.SlashTrailEnabled then return end

	-- Create arc part
	local midPoint = (startPos + endPos) / 2 + Vector3.new(0, 1, 0)
	local direction = (endPos - startPos)
	local length = direction.Magnitude

	-- OPTIMIZATION: Get from Pool
	local slash = slashPool.Get()
	slash.Color = EffectsConfig.SlashTrailColor
	slash.Transparency = 0.3
	slash.Size = Vector3.new(length, 0.1, 0.5)

	-- Position and rotate to face direction
	slash.CFrame = CFrame.lookAt(midPoint, endPos) * CFrame.Angles(0, 0, math.rad(90))
	slash.Parent = workspace

	-- Fade out
	local fadeTween = TweenService:Create(
		slash,
		TweenInfo.new(EffectsConfig.SlashTrailLifetime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Transparency = 1, Size = Vector3.new(length * 1.2, 0.05, 0.3) }
	)
	fadeTween:Play()

    -- OPTIMIZATION: Return to Pool instead of Debris
    task.delay(EffectsConfig.SlashTrailLifetime + 0.1, function()
        slashPool.Return(slash)
    end)
end

--[[
    Create hit spark particles at impact point
]]
function CombatEffects:SpawnHitSpark(position: Vector3, normal: Vector3?, comboHit: number?)
	if not EffectsConfig.HitSparkEnabled then return end

	normal = normal or Vector3.new(0, 1, 0)
	comboHit = comboHit or 1

	-- OPTIMIZATION: Get Attachment+Emitter from Pool
	local sparkItem = sparkPool.Get()
	local attachment = sparkItem.Attachment
	local sparks = sparkItem.Emitter

	attachment.WorldPosition = position
	attachment.Parent = workspace.Terrain

	-- Reset/Set properties (Batch property setting where possible)
	sparks.Color = ColorSequence.new(EffectsConfig.HitSparkColor)
	sparks.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(0.3, 0.3),
		NumberSequenceKeypoint.new(1, 0),
	})
	sparks.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.5, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	sparks.LightEmission = 1
	sparks.LightInfluence = 0
	sparks.Lifetime = NumberRange.new(0.1, 0.2)
	sparks.Speed = NumberRange.new(10, 20)
	sparks.SpreadAngle = Vector2.new(45, 45)
	sparks.Drag = 5
	sparks.Rate = 0

	-- Scale particle count by combo hit
	local particleCount = EffectsConfig.HitSparkCount + (comboHit - 1) * 4
	sparks:Emit(particleCount)

    -- Return to pool after particles die
    task.delay(0.3, function()
        sparkPool.Return(sparkItem)
    end)

	-- Flash effect
	-- OPTIMIZATION: Get from Pool
	local flash = flashPool.Get()
	flash.Color = EffectsConfig.HitSparkColor
	flash.Transparency = 0.5
	flash.Size = Vector3.new(1, 1, 1) * (1 + comboHit * 0.3)
	flash.Position = position
	flash.Parent = workspace

	-- Flash animation
	local flashTween = TweenService:Create(
		flash,
		TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(2, 2, 2) * (1 + comboHit * 0.3), Transparency = 1 }
	)
	flashTween:Play()

    task.delay(0.15, function()
        flashPool.Return(flash)
    end)
end

--[[
    Create impact ring for finisher hits (3rd hit in combo)
]]
function CombatEffects:SpawnImpactRing(position: Vector3, comboHit: number?)
	if not EffectsConfig.ImpactRingEnabled then return end

	comboHit = comboHit or 3
	if comboHit < 3 then return end

	-- OPTIMIZATION: Get from Pool
	local ring = ringPool.Get()
	ring.Color = EffectsConfig.ImpactRingColor
	ring.Transparency = 0.3
	ring.Size = Vector3.new(0.5, 0.1, 0.5)
	ring.CFrame = CFrame.new(position) * CFrame.Angles(math.rad(90), 0, 0)
	ring.Parent = workspace

	-- Expand animation
	local targetSize = EffectsConfig.ImpactRingSize
	local expandTween = TweenService:Create(
		ring,
		TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(targetSize, 0.1, targetSize) }
	)

	-- Fade animation
	local fadeTween = TweenService:Create(ring, TweenInfo.new(0.2, Enum.EasingStyle.Linear), { Transparency = 1 })

	expandTween:Play()
	task.delay(0.1, function()
		fadeTween:Play()
	end)

    task.delay(0.35, function()
        ringPool.Return(ring)
    end)

	-- Secondary inner ring
	-- Optimization: reuse ring logic/pool or make a separate pool if properties differ vastly
	-- For now, clone logic implies we need another instance. We'll use the pool again.
	local innerRing = ringPool.Get()
	innerRing.Size = Vector3.new(0.3, 0.15, 0.3)
	innerRing.Color = Color3.fromRGB(255, 255, 255)
    innerRing.CFrame = CFrame.new(position) * CFrame.Angles(math.rad(90), 0, 0)
    innerRing.Transparency = 0.3
	innerRing.Parent = workspace

	local innerExpand = TweenService:Create(
		innerRing,
		TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(targetSize * 0.6, 0.1, targetSize * 0.6), Transparency = 1 }
	)
	innerExpand:Play()

    task.delay(0.25, function()
        ringPool.Return(innerRing)
    end)
end

--[[
    Create fire-themed hit spark for Biker King attacks.
]]
function CombatEffects:SpawnFireHitEffect(position: Vector3, comboHit: number?)
	comboHit = comboHit or 1

    -- NOTE: For full optimization, fire effects should also be pooled.
    -- Assuming nozzle attachment logic is rare or special.
    -- We will pool the Fallback case which is common.

    -- Using the same spark pool but overriding properties
	local sparkItem = sparkPool.Get()
    local attachment = sparkItem.Attachment
    local sparks = sparkItem.Emitter

	attachment.WorldPosition = position
	attachment.Parent = workspace.Terrain

    -- Fire settings
    sparks.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 200, 50)),
        ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 100, 0)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(200, 30, 0)),
    })
    sparks.Size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.6),
        NumberSequenceKeypoint.new(0.3, 0.4),
        NumberSequenceKeypoint.new(1, 0),
    })
    sparks.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0),
        NumberSequenceKeypoint.new(0.5, 0.3),
        NumberSequenceKeypoint.new(1, 1),
    })
    sparks.Lifetime = NumberRange.new(0.15, 0.3)
    sparks.Speed = NumberRange.new(8, 18)
    sparks.SpreadAngle = Vector2.new(50, 50)
    sparks.Rate = 0
    sparks:Emit(8 + comboHit * 4)

    task.delay(0.4, function()
        sparkPool.Return(sparkItem)
    end)

	-- Fire flash (Reuse flash pool with different color)
	local flash = flashPool.Get()
	flash.Color = Color3.fromRGB(255, 120, 0)
	flash.Transparency = 0.3
	flash.Size = Vector3.new(1.5, 1.5, 1.5) * (1 + comboHit * 0.3)
	flash.Position = position
	flash.Parent = workspace

	TweenService:Create(
		flash,
		TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(3, 3, 3) * (1 + comboHit * 0.3), Transparency = 1 }
	):Play()

    task.delay(0.15, function()
        flashPool.Return(flash)
    end)
end

--[[
    Spawn all hit effects at once
]]
function CombatEffects:SpawnHitEffects(position: Vector3, normal: Vector3?, comboHit: number)
	-- Hit spark
	self:SpawnHitSpark(position, normal, comboHit)

	-- Impact ring for finisher
	if comboHit >= 3 then
		self:SpawnImpactRing(position, comboHit)
	end
end

--[[
    Create debug hitbox visualization
]]
function CombatEffects:VisualizeHitbox(cframe: CFrame, size: Vector3, duration: number?, didHit: boolean?)
	if not CombatConfig.Hitbox.DebugVisualize then return end

	duration = duration or 0.2
	local hitboxColor = if didHit then Color3.fromRGB(0, 255, 100) else CombatConfig.Hitbox.DebugColor

	local hitbox = Instance.new("Part")
	hitbox.Name = "DebugHitbox"
	hitbox.Anchored = true
	hitbox.CanCollide = false
	hitbox.CanQuery = false
	hitbox.CanTouch = false
	hitbox.CastShadow = false
	hitbox.Material = Enum.Material.Neon
	hitbox.Color = hitboxColor
	hitbox.Transparency = CombatConfig.Hitbox.DebugTransparency
	hitbox.Size = size
	hitbox.CFrame = cframe
	hitbox.Parent = workspace

	local selectionBox = Instance.new("SelectionBox")
	selectionBox.Adornee = hitbox
	selectionBox.Color3 = hitboxColor
	selectionBox.LineThickness = 0.05
	selectionBox.Transparency = 0
	selectionBox.Parent = hitbox

	local highlight = Instance.new("Highlight")
	highlight.Adornee = hitbox
	highlight.FillColor = hitboxColor
	highlight.FillTransparency = 0.5
	highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
	highlight.OutlineTransparency = 0
	highlight.Parent = hitbox

	local fadeTween = TweenService:Create(hitbox, TweenInfo.new(duration, Enum.EasingStyle.Linear), { Transparency = 1 })
	fadeTween:Play()

	local highlightFade = TweenService:Create(
		highlight,
		TweenInfo.new(duration, Enum.EasingStyle.Linear),
		{ FillTransparency = 1, OutlineTransparency = 1 }
	)
	highlightFade:Play()

	Debris:AddItem(hitbox, duration + 0.05)
	return hitbox
end

--[[
    Update hitbox color after hit detection
]]
function CombatEffects:UpdateHitboxColor(hitbox: Part, didHit: boolean)
	if not hitbox or not hitbox.Parent then return end
	local newColor = if didHit then Color3.fromRGB(0, 255, 100) else Color3.fromRGB(255, 50, 50)
	hitbox.Color = newColor
	local selectionBox = hitbox:FindFirstChildOfClass("SelectionBox")
	if selectionBox then selectionBox.Color3 = newColor end
	local highlight = hitbox:FindFirstChildOfClass("Highlight")
	if highlight then highlight.FillColor = newColor end
end

--[[
    Spawn knockback effect on enemy
]]
function CombatEffects:SpawnKnockbackTrail(character: Model, direction: Vector3)
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return end

    -- Optimization: Could pool this too, but leaving for now as it's less frequent
	local attachment = Instance.new("Attachment")
	attachment.Parent = rootPart
	local trail = Instance.new("ParticleEmitter")
	trail.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
	trail.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 0)})
	trail.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1)})
	trail.Lifetime = NumberRange.new(0.1, 0.15)
	trail.Speed = NumberRange.new(0, 0)
	trail.Rate = 30
	trail.Parent = attachment

	task.delay(0.2, function() trail.Enabled = false end)
	Debris:AddItem(attachment, 0.5)
end

return CombatEffects
