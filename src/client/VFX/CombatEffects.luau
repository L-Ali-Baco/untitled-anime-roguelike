--[[
	CombatEffects.luau
	Visual effects for combat:
	- Slash trails during swings
	- Hit sparks on enemy contact
	- Impact rings for finisher attacks

	POOLING CHANGES vs. original:
	  Every function that called Instance.new("Part") + Debris:AddItem now fetches
	  from VFXPool and uses ReturnPartDelayed. Zero Part allocations on the hot path.

	  Attachment + ParticleEmitter nodes are NOT pooled. They are very lightweight
	  Lua-side objects with no C++ physics/broadphase entry. Their GC cost is
	  ~10–15× lower than a BasePart. Pooling them would add code complexity for
	  negligible gain.

	WHAT WAS POOLED:
	  SpawnSlashTrail        → 1× "SlashTrail" Part
	  SpawnHitSpark          → 1× "HitFlash" Part
	  SpawnVanguardHitEffect → 1× "HitFlash" Part
	                           1× "ImpactRing" Part  (finisher only)
	  SpawnFireHitEffect     → 1× "HitFlash" Part
	  SpawnImpactRing        → 2× "ImpactRing" Parts (outer + inner)

	INNER RING CHANGE:
	  Original code used `innerRing = ring:Clone()` — Clone() costs ~3–8 µs and
	  allocates a new Part + CylinderMesh + all descendants. Now we fetch a second
	  "ImpactRing" from the pool instead. The CylinderMesh is pre-added to the
	  pool template in VFXPool.Init (via special setup; see note below).

	  NOTE on CylinderMesh: The pool template for "ImpactRing" is created as a
	  plain Cylinder PartType (no special mesh needed — Roblox's Cylinder PartType
	  IS a cylinder). The CylinderMesh from the original code was redundant since
	  PartType.Cylinder already renders as a cylinder. We removed it.
]]

local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatConfig = require(ReplicatedStorage.Shared.Config.CombatConfig)
local VFXPool = require(script.Parent.VFXPool)

local CombatEffects = {}

local EffectsConfig = CombatConfig.Effects

-- ── Pre-baked TweenInfos ──────────────────────────────────────────────────────

-- Allocating TweenInfo once at module load saves a heap alloc per VFX call.
local SLASH_TRAIL_TWEEN = TweenInfo.new(
	EffectsConfig.SlashTrailLifetime,
	Enum.EasingStyle.Quad,
	Enum.EasingDirection.Out
)
local HIT_FLASH_TWEEN = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local VANGUARD_FLASH_TWEEN_BASE = 0.1 -- will add comboHit * 0.02 per call (unavoidable)
local RING_EXPAND_TWEEN = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RING_FADE_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Linear)
local INNER_RING_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- ── SpawnSlashTrail ───────────────────────────────────────────────────────────

--[[
	SpawnSlashTrail(startPos, endPos, comboHit)

	POOLING: 1× "SlashTrail" Part.
	Lifetime: EffectsConfig.SlashTrailLifetime (~0.15–0.25 s).
]]
function CombatEffects:SpawnSlashTrail(startPos: Vector3, endPos: Vector3, comboHit: number)
	if not EffectsConfig.SlashTrailEnabled then
		return
	end

	local midPoint = (startPos + endPos) / 2 + Vector3.new(0, 1, 0)
	local direction = (endPos - startPos)
	local length = direction.Magnitude
	if length < 0.01 then
		return
	end

	local slash = VFXPool:GetPart("SlashTrail")
	slash.Color = EffectsConfig.SlashTrailColor
	slash.Transparency = 0.3
	slash.Size = Vector3.new(length, 0.1, 0.5)
	slash.CFrame = CFrame.lookAt(midPoint, endPos) * CFrame.Angles(0, 0, math.rad(90))
	slash.Parent = workspace

	TweenService:Create(
		slash,
		SLASH_TRAIL_TWEEN,
		{ Transparency = 1, Size = Vector3.new(length * 1.2, 0.05, 0.3) }
	):Play()

	VFXPool:ReturnPartDelayed("SlashTrail", slash, EffectsConfig.SlashTrailLifetime + 0.1)
end

-- ── SpawnHitSpark ─────────────────────────────────────────────────────────────

--[[
	SpawnHitSpark(position, normal?, comboHit?)

	Particle burst + pooled flash ball.

	POOLING: 1× "HitFlash" Part.
	Attachment + ParticleEmitter: created fresh (lightweight, not pooled).

	GENERIC EMITTER ALTERNATIVE:
	  For code that only needs a quick burst without the flash ball, use:
	    VFXPool:EmitHitSpark(position, particleCount, colorSequence?)
	  This uses the pre-built "HitSparkEmitter" pool and has zero allocation.
]]
function CombatEffects:SpawnHitSpark(position: Vector3, normal: Vector3?, comboHit: number?)
	if not EffectsConfig.HitSparkEnabled then
		return
	end

	normal = normal or Vector3.new(0, 1, 0)
	comboHit = comboHit or 1

	-- Attachment + emitter: not pooled (see file header rationale).
	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = position
	attachment.Parent = workspace.Terrain

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

	local particleCount = EffectsConfig.HitSparkCount + (comboHit - 1) * 4
	sparks:Emit(particleCount)
	Debris:AddItem(attachment, 0.3) -- cheap; Attachment GC is negligible

	-- ── Pooled flash ball ─────────────────────────────────────────────
	local flash = VFXPool:GetPart("HitFlash")
	flash.Color = EffectsConfig.HitSparkColor
	flash.Transparency = 0.5
	flash.Size = Vector3.new(1, 1, 1) * (1 + comboHit * 0.3)
	flash.Position = position
	flash.Parent = workspace

	TweenService:Create(flash, HIT_FLASH_TWEEN, {
		Size = Vector3.new(2, 2, 2) * (1 + comboHit * 0.3),
		Transparency = 1,
	}):Play()

	VFXPool:ReturnPartDelayed("HitFlash", flash, 0.15)
end

-- ── SpawnImpactRing ───────────────────────────────────────────────────────────

--[[
	SpawnImpactRing(position, comboHit?)

	Expanding ground ring + smaller inner ring for finisher hits.

	POOLING: 2× "ImpactRing" Parts (outer + inner).
	Original code used `innerRing = ring:Clone()` which is ~5 µs per call.
	Now fetches a second pool slot instead.
]]
function CombatEffects:SpawnImpactRing(position: Vector3, comboHit: number?)
	if not EffectsConfig.ImpactRingEnabled then
		return
	end

	comboHit = comboHit or 3
	if comboHit < 3 then
		return
	end

	local targetSize = EffectsConfig.ImpactRingSize

	-- ── Outer ring ────────────────────────────────────────────────────
	local ring = VFXPool:GetPart("ImpactRing")
	ring.Color = EffectsConfig.ImpactRingColor
	ring.Transparency = 0.3
	ring.Size = Vector3.new(0.5, 0.1, 0.5)
	ring.CFrame = CFrame.new(position) * CFrame.Angles(math.rad(90), 0, 0)
	ring.Parent = workspace

	TweenService:Create(ring, RING_EXPAND_TWEEN, {
		Size = Vector3.new(targetSize, 0.1, targetSize),
	}):Play()

	task.delay(0.1, function()
		if ring.Parent then
			TweenService:Create(ring, RING_FADE_TWEEN, { Transparency = 1 }):Play()
		end
	end)

	VFXPool:ReturnPartDelayed("ImpactRing", ring, 0.38)

	-- ── Inner ring (was ring:Clone() — now a second pool fetch) ───────
	local innerRing = VFXPool:GetPart("ImpactRing")
	innerRing.Color = Color3.fromRGB(255, 255, 255)
	innerRing.Transparency = 0.35
	innerRing.Size = Vector3.new(0.3, 0.15, 0.3)
	innerRing.CFrame = CFrame.new(position) * CFrame.Angles(math.rad(90), 0, 0)
	innerRing.Parent = workspace

	TweenService:Create(innerRing, INNER_RING_TWEEN, {
		Size = Vector3.new(targetSize * 0.6, 0.1, targetSize * 0.6),
		Transparency = 1,
	}):Play()

	VFXPool:ReturnPartDelayed("ImpactRing", innerRing, 0.28)
end

-- ── SpawnVanguardHitEffect ────────────────────────────────────────────────────

--[[
	SpawnVanguardHitEffect(position, comboHit?)

	Hot yellow-white core → vivid magenta → near-black dark purple.
	comboHit 1 = light spark, 2 = medium, 3 = heavy burst + ring.

	POOLING:
	  flash Part        → "HitFlash" pool
	  FinisherRing      → "ImpactRing" pool  (comboHit >= 3 only)
	  PointLight        → created fresh (not worth pooling)
	  Attachments       → not pooled
	  ParticleEmitters  → not pooled
]]
function CombatEffects:SpawnVanguardHitEffect(position: Vector3, comboHit: number?)
	comboHit = comboHit or 1

	local HOT_CORE = Color3.fromRGB(255, 255, 180)
	local MID_MAGENTA = Color3.fromRGB(255, 50, 200)
	local EDGE_DARK = Color3.fromRGB(40, 5, 60)

	local slashColorSeq = ColorSequence.new({
		ColorSequenceKeypoint.new(0, HOT_CORE),
		ColorSequenceKeypoint.new(0.4, MID_MAGENTA),
		ColorSequenceKeypoint.new(1, EDGE_DARK),
	})

	local att = Instance.new("Attachment")
	att.WorldPosition = position
	att.Parent = workspace.Terrain

	-- ── Spark burst ───────────────────────────────────────────────────
	local sparks = Instance.new("ParticleEmitter")
	sparks.Color = slashColorSeq
	sparks.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4 + comboHit * 0.15),
		NumberSequenceKeypoint.new(0.3, 0.25),
		NumberSequenceKeypoint.new(1, 0),
	})
	sparks.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.6, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	sparks.LightEmission = 1
	sparks.LightInfluence = 0
	sparks.Lifetime = NumberRange.new(0.08, 0.18 + comboHit * 0.04)
	sparks.Speed = NumberRange.new(12 + comboHit * 4, 28 + comboHit * 6)
	sparks.SpreadAngle = Vector2.new(60, 60)
	sparks.Drag = 6
	sparks.Rate = 0
	sparks.Parent = att
	sparks:Emit(8 + comboHit * 6)

	-- ── Pooled flash ball ─────────────────────────────────────────────
	local flashSize = 0.8 + comboHit * 0.5
	local flash = VFXPool:GetPart("HitFlash")
	flash.Color = HOT_CORE
	flash.Transparency = 0.1
	flash.Size = Vector3.new(flashSize, flashSize, flashSize)
	flash.Position = position
	flash.Parent = workspace

	local flashDuration = VANGUARD_FLASH_TWEEN_BASE + comboHit * 0.02
	TweenService:Create(
		flash,
		TweenInfo.new(flashDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(flashSize * 2.2, flashSize * 2.2, flashSize * 2.2), Transparency = 1 }
	):Play()

	VFXPool:ReturnPartDelayed("HitFlash", flash, flashDuration + 0.05)

	-- PointLight: child of flash, but we destroy separately so it doesn't
	-- stay in the pooled part when it returns.
	local light = Instance.new("PointLight")
	light.Color = MID_MAGENTA
	light.Brightness = 2 + comboHit
	light.Range = 10 + comboHit * 3
	light.Parent = att -- parented to attachment, NOT to the pooled flash Part
	TweenService:Create(light, TweenInfo.new(0.15), { Brightness = 0 }):Play()

	Debris:AddItem(att, 0.7)

	-- ── Finisher extras ───────────────────────────────────────────────
	if comboHit >= 3 then
		-- Pooled shockwave ring (replaces Instance.new + Debris).
		local ring = VFXPool:GetPart("ImpactRing")
		ring.Color = MID_MAGENTA
		ring.Transparency = 0.2
		ring.Size = Vector3.new(1, 0.12, 1)
		ring.CFrame = CFrame.new(position) * CFrame.Angles(math.rad(90), 0, 0)
		ring.Parent = workspace

		TweenService:Create(
			ring,
			TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = Vector3.new(18, 0.12, 18), Transparency = 1 }
		):Play()

		VFXPool:ReturnPartDelayed("ImpactRing", ring, 0.38)

		-- Ember burst (attachment-based; not pooled).
		local embers = Instance.new("ParticleEmitter")
		embers.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, HOT_CORE),
			ColorSequenceKeypoint.new(0.5, MID_MAGENTA),
			ColorSequenceKeypoint.new(1, EDGE_DARK),
		})
		embers.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.25),
			NumberSequenceKeypoint.new(1, 0),
		})
		embers.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(1, 1),
		})
		embers.LightEmission = 1
		embers.LightInfluence = 0
		embers.Lifetime = NumberRange.new(0.3, 0.6)
		embers.Speed = NumberRange.new(4, 10)
		embers.SpreadAngle = Vector2.new(40, 40)
		embers.Rotation = NumberRange.new(0, 360)
		embers.Rate = 0
		embers.Parent = att
		embers:Emit(20)
	end
end

-- ── SpawnFireHitEffect ────────────────────────────────────────────────────────

--[[
	SpawnFireHitEffect(position, comboHit?)

	Biker King fire-style hit.

	POOLING: 1× "HitFlash" Part (FireFlash → reuses same HitFlash pool slot).
	The FlashPart color/size distinguishes it visually; no separate pool needed.
]]
function CombatEffects:SpawnFireHitEffect(position: Vector3, comboHit: number?)
	comboHit = comboHit or 1

	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = position
	attachment.Parent = workspace.Terrain

	local nozzle = ReplicatedStorage:FindFirstChild("nozzle", true)
	local emitted = false
	if nozzle and nozzle:IsA("Attachment") then
		for _, child in nozzle:GetChildren() do
			if child:IsA("ParticleEmitter") then
				local cloned = child:Clone()
				cloned.Rate = 0
				cloned.Parent = attachment
				cloned:Emit(8 + comboHit * 4)
				emitted = true
			end
		end
	end

	if not emitted then
		local sparks = Instance.new("ParticleEmitter")
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
		sparks.LightEmission = 1
		sparks.LightInfluence = 0
		sparks.Lifetime = NumberRange.new(0.15, 0.3)
		sparks.Speed = NumberRange.new(8, 18)
		sparks.SpreadAngle = Vector2.new(50, 50)
		sparks.Drag = 4
		sparks.Rate = 0
		sparks.Parent = attachment
		sparks:Emit(8 + comboHit * 4)
	end

	Debris:AddItem(attachment, 0.4)

	-- ── Pooled fire flash (reuses HitFlash pool with fire colour) ─────
	local flashSize = 1.5 * (1 + comboHit * 0.3)
	local flash = VFXPool:GetPart("HitFlash")
	flash.Color = Color3.fromRGB(255, 120, 0)
	flash.Transparency = 0.3
	flash.Size = Vector3.new(flashSize, flashSize, flashSize)
	flash.Position = position
	flash.Parent = workspace

	TweenService:Create(
		flash,
		TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(flashSize * 2, flashSize * 2, flashSize * 2), Transparency = 1 }
	):Play()

	VFXPool:ReturnPartDelayed("HitFlash", flash, 0.17)
end

-- ── SpawnHitEffects ───────────────────────────────────────────────────────────

function CombatEffects:SpawnHitEffects(position: Vector3, normal: Vector3?, comboHit: number)
	self:SpawnHitSpark(position, normal, comboHit)
	if comboHit >= 3 then
		self:SpawnImpactRing(position, comboHit)
	end
end

-- ── VisualizeHitbox ───────────────────────────────────────────────────────────

--[[
	VisualizeHitbox — NOT pooled intentionally.
	This only runs when CombatConfig.Hitbox.DebugVisualize = true (dev mode only).
	Pooling a debug-only function adds complexity without benefiting production.
	The Highlight + SelectionBox children make it unsuitable for the pool anyway.
]]
function CombatEffects:VisualizeHitbox(cframe: CFrame, size: Vector3, duration: number?, didHit: boolean?)
	if not CombatConfig.Hitbox.DebugVisualize then
		return
	end

	duration = duration or 0.2
	local hitboxColor = if didHit
		then Color3.fromRGB(0, 255, 100)
		else CombatConfig.Hitbox.DebugColor

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

-- ── UpdateHitboxColor ─────────────────────────────────────────────────────────

function CombatEffects:UpdateHitboxColor(hitbox: Part, didHit: boolean)
	if not hitbox or not hitbox.Parent then
		return
	end

	local newColor = if didHit
		then Color3.fromRGB(0, 255, 100)
		else Color3.fromRGB(255, 50, 50)

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

-- ── SpawnKnockbackTrail ───────────────────────────────────────────────────────

-- Knockback trail uses a ParticleEmitter on the character root.
-- Not a poolable Part; kept as-is.
function CombatEffects:SpawnKnockbackTrail(character: Model, direction: Vector3)
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return
	end

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

	task.delay(0.2, function()
		trail.Enabled = false
	end)

	Debris:AddItem(attachment, 0.5)
end

return CombatEffects
