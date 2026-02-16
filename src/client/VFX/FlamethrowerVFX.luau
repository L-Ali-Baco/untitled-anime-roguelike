--[[
	FlamethrowerVFX.luau — Biker King M1 Flamethrower

	Simple 3-layer approach. One attachment. No overengineering.
	  Layer 1: Bright core  (4x4 flipbook)
	  Layer 2: Outer body   (4x4 flipbook)
	  Layer 3: Edge detail  (8x8 flipbook)

	Compressed at muzzle → fans out at range via spread + drag.
	Warm saturated colours, no pure black.
]]

local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local FlamethrowerVFX = {}
FlamethrowerVFX.Name = "FlamethrowerVFX"

-- Flipbook textures
local TEX_FIRE_A = "rbxassetid://13528076463" -- 4x4
local TEX_DETAIL = "rbxassetid://10768424377" -- 8x8
local TEX_FIRE_B = "rbxassetid://9754671071" -- 4x4

-- Colours
local WHITE_HOT = Color3.fromRGB(255, 250, 215)
local YELLOW = Color3.fromRGB(255, 215, 50)
local AMBER = Color3.fromRGB(255, 165, 30)
local ORANGE = Color3.fromRGB(240, 105, 15)
local CRIMSON = Color3.fromRGB(195, 45, 20)
local MAROON = Color3.fromRGB(90, 20, 10)

-- State
local stream = {
	active = false,
	attachment = nil :: Attachment?,
	emitters = {} :: { ParticleEmitter },
	light = nil :: PointLight?,
}

local function applyFlipbook(e: ParticleEmitter, layout: Enum.ParticleFlipbookLayout)
	e.FlipbookLayout = layout
	e.FlipbookMode = Enum.ParticleFlipbookMode.OneShot
	e.FlipbookFramerate = NumberRange.new(22, 28)
end

-- ═══════════════════════════════════════════════════════════════════

function FlamethrowerVFX:StartStream(rootPart: BasePart)
	if stream.active then
		return
	end

	local att = Instance.new("Attachment")
	att.Name = "FlameMuzzle"
	att.Position = Vector3.new(0, 0.5, -3)
	att.Parent = rootPart

	local emitters = {}

	-- ── Layer 1: Bright Core ─────────────────────────────────────
	local core = Instance.new("ParticleEmitter")
	core.Name = "Core"
	core.Texture = TEX_FIRE_A
	applyFlipbook(core, Enum.ParticleFlipbookLayout.Grid4x4)

	core.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, WHITE_HOT),
		ColorSequenceKeypoint.new(0.15, YELLOW),
		ColorSequenceKeypoint.new(0.45, AMBER),
		ColorSequenceKeypoint.new(1, ORANGE),
	})
	core.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(0.06, 0.5),
		NumberSequenceKeypoint.new(0.2, 1.8),
		NumberSequenceKeypoint.new(0.5, 3.5),
		NumberSequenceKeypoint.new(1, 4.0),
	})
	core.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(0.15, 0),
		NumberSequenceKeypoint.new(0.6, 0),
		NumberSequenceKeypoint.new(0.85, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})

	core.LightEmission = 1
	core.LightInfluence = 0
	core.Speed = NumberRange.new(50, 65)
	core.Lifetime = NumberRange.new(0.5, 0.75)
	core.SpreadAngle = Vector2.new(4, 4)
	core.Drag = 1.5
	core.Acceleration = Vector3.new(0, 2, 0)
	core.Rate = 80
	core.Rotation = NumberRange.new(0, 360)
	core.RotSpeed = NumberRange.new(-90, 90)
	core.EmissionDirection = Enum.NormalId.Front
	core.ZOffset = 1
	core.Enabled = false
	core.Parent = att
	table.insert(emitters, core)

	-- ── Layer 2: Outer Body ──────────────────────────────────────
	local outer = Instance.new("ParticleEmitter")
	outer.Name = "Outer"
	outer.Texture = TEX_FIRE_B
	applyFlipbook(outer, Enum.ParticleFlipbookLayout.Grid4x4)

	outer.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, AMBER),
		ColorSequenceKeypoint.new(0.2, ORANGE),
		ColorSequenceKeypoint.new(0.5, CRIMSON),
		ColorSequenceKeypoint.new(1, MAROON),
	})
	outer.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(0.06, 0.8),
		NumberSequenceKeypoint.new(0.2, 2.5),
		NumberSequenceKeypoint.new(0.5, 5.0),
		NumberSequenceKeypoint.new(1, 5.5),
	})
	outer.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(0.15, 0),
		NumberSequenceKeypoint.new(0.55, 0),
		NumberSequenceKeypoint.new(0.8, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})

	outer.LightEmission = 0.75
	outer.LightInfluence = 0
	outer.Speed = NumberRange.new(45, 60)
	outer.Lifetime = NumberRange.new(0.55, 0.8)
	outer.SpreadAngle = Vector2.new(6, 6)
	outer.Drag = 1.5
	outer.Acceleration = Vector3.new(0, 3, 0)
	outer.Rate = 65
	outer.Rotation = NumberRange.new(0, 360)
	outer.RotSpeed = NumberRange.new(-120, 120)
	outer.EmissionDirection = Enum.NormalId.Front
	outer.ZOffset = 0
	outer.Enabled = false
	outer.Parent = att
	table.insert(emitters, outer)

	-- ── Layer 3: Edge Detail ─────────────────────────────────────
	local detail = Instance.new("ParticleEmitter")
	detail.Name = "Detail"
	detail.Texture = TEX_DETAIL
	applyFlipbook(detail, Enum.ParticleFlipbookLayout.Grid8x8)

	detail.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, ORANGE),
		ColorSequenceKeypoint.new(0.3, CRIMSON),
		ColorSequenceKeypoint.new(1, MAROON),
	})
	detail.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(0.1, 1.2),
		NumberSequenceKeypoint.new(0.35, 3.0),
		NumberSequenceKeypoint.new(0.7, 4.5),
		NumberSequenceKeypoint.new(1, 4.8),
	})
	detail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(0.15, 0.3),
		NumberSequenceKeypoint.new(0.5, 0.35),
		NumberSequenceKeypoint.new(0.8, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})

	detail.LightEmission = 0.3
	detail.LightInfluence = 0
	detail.Speed = NumberRange.new(42, 58)
	detail.Lifetime = NumberRange.new(0.5, 0.75)
	detail.SpreadAngle = Vector2.new(7, 7)
	detail.Drag = 1.6
	detail.Acceleration = Vector3.new(0, 3, 0)
	detail.Rate = 30
	detail.Rotation = NumberRange.new(0, 360)
	detail.RotSpeed = NumberRange.new(-150, 150)
	detail.EmissionDirection = Enum.NormalId.Front
	detail.ZOffset = -1
	detail.Enabled = false
	detail.Parent = att
	table.insert(emitters, detail)

	-- ── Light ────────────────────────────────────────────────────
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 155, 45)
	light.Range = 35
	light.Brightness = 3
	light.Parent = att

	-- Enable
	for _, e in emitters do
		e.Enabled = true
	end

	stream.active = true
	stream.attachment = att
	stream.emitters = emitters
	stream.light = light
end

function FlamethrowerVFX:StopStream()
	if not stream.active then
		return
	end
	stream.active = false

	for _, e in stream.emitters do
		if e then
			e.Enabled = false
		end
	end

	if stream.light then
		TweenService:Create(stream.light, TweenInfo.new(0.2), { Brightness = 0 }):Play()
	end

	if stream.attachment then
		Debris:AddItem(stream.attachment, 1.0)
		stream.attachment = nil
	end

	stream.emitters = {}
	stream.light = nil
end

function FlamethrowerVFX:PlayHitEffect(position: Vector3)
	local att = Instance.new("Attachment")
	att.WorldPosition = position
	att.Parent = workspace.Terrain

	local burst = Instance.new("ParticleEmitter")
	burst.Texture = TEX_FIRE_A
	applyFlipbook(burst, Enum.ParticleFlipbookLayout.Grid4x4)
	burst.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, WHITE_HOT),
		ColorSequenceKeypoint.new(0.2, ORANGE),
		ColorSequenceKeypoint.new(1, MAROON),
	})
	burst.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.8),
		NumberSequenceKeypoint.new(0.3, 2.0),
		NumberSequenceKeypoint.new(1, 0),
	})
	burst.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.5, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	burst.LightEmission = 1
	burst.LightInfluence = 0
	burst.Speed = NumberRange.new(6, 14)
	burst.Lifetime = NumberRange.new(0.15, 0.3)
	burst.SpreadAngle = Vector2.new(60, 60)
	burst.Drag = 5
	burst.Rate = 0
	burst.Rotation = NumberRange.new(0, 360)
	burst.RotSpeed = NumberRange.new(-200, 200)
	burst.Parent = att
	burst:Emit(10)

	local flash = Instance.new("PointLight")
	flash.Color = Color3.fromRGB(255, 140, 35)
	flash.Brightness = 3
	flash.Range = 8
	flash.Parent = att
	TweenService:Create(flash, TweenInfo.new(0.12), { Brightness = 0 }):Play()

	Debris:AddItem(att, 0.5)
end

function FlamethrowerVFX:PlayRangedHitEffects(_origin, hitPos, _normal, _data)
	self:PlayHitEffect(hitPos)
end

function FlamethrowerVFX:PlayRangedMissEffects(...) end

return FlamethrowerVFX
