--[[
    CombatEffects.luau
    Visual effects for combat:
    - Slash trails during swings
    - Hit sparks on enemy contact
    - Impact rings for finisher attacks
]]

local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatConfig = require(ReplicatedStorage.Shared.Config.CombatConfig)

local CombatEffects = {}

-- Config shorthand
local EffectsConfig = CombatConfig.Effects

--[[
    Create a slash arc trail effect
]]
function CombatEffects:SpawnSlashTrail(startPos: Vector3, endPos: Vector3, comboHit: number)
	if not EffectsConfig.SlashTrailEnabled then
		return
	end

	-- Create arc part
	local midPoint = (startPos + endPos) / 2 + Vector3.new(0, 1, 0)
	local direction = (endPos - startPos)
	local length = direction.Magnitude

	local slash = Instance.new("Part")
	slash.Name = "SlashTrail"
	slash.Anchored = true
	slash.CanCollide = false
	slash.CanQuery = false
	slash.CanTouch = false
	slash.CastShadow = false
	slash.Material = Enum.Material.Neon
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

	Debris:AddItem(slash, EffectsConfig.SlashTrailLifetime + 0.1)
end

--[[
    Create hit spark particles at impact point
]]
function CombatEffects:SpawnHitSpark(position: Vector3, normal: Vector3?, comboHit: number?)
	if not EffectsConfig.HitSparkEnabled then
		return
	end

	normal = normal or Vector3.new(0, 1, 0)
	comboHit = comboHit or 1

	-- Create attachment for particles
	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = position
	attachment.Parent = workspace.Terrain

	-- Spark particles
	local sparks = Instance.new("ParticleEmitter")
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
	sparks.Parent = attachment

	-- Scale particle count by combo hit
	local particleCount = EffectsConfig.HitSparkCount + (comboHit - 1) * 4
	sparks:Emit(particleCount)

	-- Flash effect
	local flash = Instance.new("Part")
	flash.Name = "HitFlash"
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.CanTouch = false
	flash.CastShadow = false
	flash.Material = Enum.Material.Neon
	flash.Color = EffectsConfig.HitSparkColor
	flash.Transparency = 0.5
	flash.Shape = Enum.PartType.Ball
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

	Debris:AddItem(attachment, 0.3)
	Debris:AddItem(flash, 0.15)
end

--[[
    Create impact ring for finisher hits (3rd hit in combo)
]]
function CombatEffects:SpawnImpactRing(position: Vector3, comboHit: number?)
	if not EffectsConfig.ImpactRingEnabled then
		return
	end

	comboHit = comboHit or 3

	-- Only spawn for finisher (3rd hit) or higher
	if comboHit < 3 then
		return
	end

	-- Create expanding ring
	local ring = Instance.new("Part")
	ring.Name = "ImpactRing"
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = EffectsConfig.ImpactRingColor
	ring.Transparency = 0.3
	ring.Size = Vector3.new(0.5, 0.1, 0.5)
	ring.CFrame = CFrame.new(position) * CFrame.Angles(math.rad(90), 0, 0)
	ring.Parent = workspace

	-- Cylinder mesh for ring shape
	local mesh = Instance.new("CylinderMesh")
	mesh.Parent = ring

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

	Debris:AddItem(ring, 0.35)

	-- Secondary inner ring
	local innerRing = ring:Clone()
	innerRing.Size = Vector3.new(0.3, 0.15, 0.3)
	innerRing.Color = Color3.fromRGB(255, 255, 255)
	innerRing.Parent = workspace

	local innerExpand = TweenService:Create(
		innerRing,
		TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(targetSize * 0.6, 0.1, targetSize * 0.6), Transparency = 1 }
	)
	innerExpand:Play()

	Debris:AddItem(innerRing, 0.25)
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
    @param cframe: Position and rotation of hitbox
    @param size: Dimensions of hitbox
    @param duration: How long to show the hitbox
    @param didHit: Whether the hitbox hit something (changes color)
]]
function CombatEffects:VisualizeHitbox(cframe: CFrame, size: Vector3, duration: number?, didHit: boolean?)
	if not CombatConfig.Hitbox.DebugVisualize then
		return
	end

	duration = duration or 0.2

	-- Color based on hit result: green = hit, red = miss
	local hitboxColor = if didHit
		then Color3.fromRGB(0, 255, 100) -- Green for hit
		else CombatConfig.Hitbox.DebugColor

	-- Main hitbox part
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

	-- Add SelectionBox for clear outline
	local selectionBox = Instance.new("SelectionBox")
	selectionBox.Adornee = hitbox
	selectionBox.Color3 = hitboxColor
	selectionBox.LineThickness = 0.05
	selectionBox.Transparency = 0
	selectionBox.Parent = hitbox

	-- Add a highlight for extra visibility
	local highlight = Instance.new("Highlight")
	highlight.Adornee = hitbox
	highlight.FillColor = hitboxColor
	highlight.FillTransparency = 0.5
	highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
	highlight.OutlineTransparency = 0
	highlight.Parent = hitbox

	-- Fade out
	local fadeTween =
		TweenService:Create(hitbox, TweenInfo.new(duration, Enum.EasingStyle.Linear), { Transparency = 1 })
	fadeTween:Play()

	-- Fade highlight too
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
    @param hitbox: The hitbox part to update
    @param didHit: Whether hits were detected
]]
function CombatEffects:UpdateHitboxColor(hitbox: Part, didHit: boolean)
	if not hitbox or not hitbox.Parent then
		return
	end

	local newColor = if didHit
		then Color3.fromRGB(0, 255, 100) -- Green for hit
		else Color3.fromRGB(255, 50, 50) -- Red for miss

	hitbox.Color = newColor

	local selectionBox = hitbox:FindFirstChildOfClass("SelectionBox")
	if selectionBox then
		selectionBox.Color3 = newColor
	end

	local highlight = hitbox:FindFirstChildOfClass("Highlight")
	if highlight then
		highlight.FillColor = newColor
	end
end

--[[
    Spawn knockback effect on enemy
]]
function CombatEffects:SpawnKnockbackTrail(character: Model, direction: Vector3)
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return
	end

	-- Speed lines attachment
	local attachment = Instance.new("Attachment")
	attachment.Parent = rootPart

	local trail = Instance.new("ParticleEmitter")
	trail.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
	trail.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(1, 0),
	})
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.Lifetime = NumberRange.new(0.1, 0.15)
	trail.Speed = NumberRange.new(0, 0)
	trail.Rate = 30
	trail.Parent = attachment

	-- Stop after short duration
	task.delay(0.2, function()
		trail.Enabled = false
	end)

	Debris:AddItem(attachment, 0.5)
end

return CombatEffects
